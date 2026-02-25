# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "utils/git"
require "formulary"
require "software_spec"
require "tap"

module Homebrew
  module DevCmd
    class Extract < AbstractCommand
      BOTTLE_BLOCK_REGEX = /  bottle (?:do.+?end|:[a-z]+)\n\n/m
      LIVECHECK_BLOCK_REGEX = /^  livecheck do\n.*?\n  end\n\n?/m
      private_constant :BOTTLE_BLOCK_REGEX, :LIVECHECK_BLOCK_REGEX

      cmd_args do
        usage_banner "`extract` [<options>] <formula>|<cask> <tap>"
        description <<~EOS
          Look through repository history to find the most recent version of <formula> or
          <cask> and create a copy in <tap>. Specifically, the command will create the new
          formula file at <tap>`/Formula/`<formula>`@`<version>`.rb` or the new cask file
          at <tap>`/Casks/`<cask>`@`<version>`.rb`. If the tap is not installed yet, attempt
          to install/clone the tap before continuing. To extract from a tap that is not
          `homebrew/core` or `homebrew/cask` use the fully-qualified form of
          <user>`/`<repo>`/`<formula>|<cask>.
        EOS
        flag   "--git-revision=",
               description: "Search for the specified <version> starting at <revision> instead of HEAD."
        flag   "--version=",
               description: "Extract the specified <version> instead of the most recent."
        switch "-f", "--force",
               description: "Overwrite the destination formula or cask if it already exists."
        switch "--unversioned",
               description: "Extract without version suffix (receives updates via `brew upgrade`)."
        switch "--remove-deprecations",
               description: "Comment out `deprecate!` and `disable!` stanzas."
        switch "--keep-livecheck",
               description: "Keep livecheck block in versioned extractions (default: remove for snapshots)."
        switch "--no-shard",
               description: "Do not organize output into sharded subdirectories."
        switch "--formula", "--formulae",
               description: "Treat all named arguments as formulae."
        switch "--cask", "--casks",
               description: "Treat all named arguments as casks."

        conflicts "--formula", "--cask"
        conflicts "--unversioned", "--version"

        named_args [:formula, :cask, :tap], number: 2, without_api: true
      end

      sig { override.void }
      def run
        first_arg = args.named.fetch(0)
        source_tap, name, is_cask = resolve_source(first_arg)
        raise TapFormulaUnavailableError.new(source_tap, name) unless source_tap.installed?

        destination_tap = Tap.fetch(args.named.fetch(1))
        unless Homebrew::EnvConfig.developer?
          odie "Cannot extract formula to homebrew/core!" if destination_tap.core_tap?
          odie "Cannot extract formula to homebrew/cask!" if destination_tap.core_cask_tap?
          odie "Cannot extract to the same tap!" if destination_tap == source_tap
        end
        destination_tap.install unless destination_tap.installed?

        if is_cask
          extract_cask_to_tap(name, source_tap, destination_tap)
        else
          extract_formula_to_tap(name, source_tap, destination_tap)
        end
      end

      private

      sig { params(first_arg: String).returns([Tap, String, T::Boolean]) }
      def resolve_source(first_arg)
        if args.casks?
          tap_with_token = Tap.with_cask_token(first_arg)
          source_tap = tap_with_token&.first || CoreCaskTap.instance
          token = tap_with_token&.last || first_arg.downcase
          [source_tap, token, true]
        elsif args.formulae?
          tap_with_name = Tap.with_formula_name(first_arg)
          source_tap = tap_with_name&.first || CoreTap.instance
          name = tap_with_name&.last || first_arg.downcase
          [source_tap, name, false]
        elsif (tap_with_name = Tap.with_formula_name(first_arg))
          [tap_with_name.first, tap_with_name.last, false]
        elsif (tap_with_token = Tap.with_cask_token(first_arg))
          [tap_with_token.first, tap_with_token.last, true]
        else
          [CoreTap.instance, first_arg.downcase, false]
        end
      end

      sig { params(name: String).returns(String) }
      def formula_shard(name)
        name.start_with?("lib") ? "lib" : name[0].to_s
      end

      sig { params(token: String).returns(String) }
      def cask_shard(token)
        if token.start_with?("font-")
          "font/font-#{token.delete_prefix("font-")[0]}"
        else
          token[0].to_s
        end
      end

      sig { params(name: String, source_tap: Tap, destination_tap: Tap).void }
      def extract_formula_to_tap(name, source_tap, destination_tap)
        repo = source_tap.path
        start_rev = args.git_revision || "HEAD"
        pattern = if source_tap.core_tap?
          [source_tap.new_formula_path(name), repo/"Formula/#{name}.rb"].uniq
        else
          # A formula can technically live in the root directory of a tap or in any of its subdirectories
          [repo/"#{name}.rb", repo/"**/#{name}.rb"]
        end

        base_name = name.sub(/\b@(.*)\z\b/i, "")

        if args.unversioned?
          files = if start_rev == "HEAD"
            Dir[repo/"{,**/}"].filter_map do |dir|
              Pathname.glob("#{dir}/#{name}.rb").find(&:file?)
            end
          else
            []
          end
          result = if files.empty?
            rev, (path,) = Utils::Git.last_revision_commit_of_files(repo, pattern, before_commit: start_rev)
            odie "Could not find #{name}! The formula may not have existed." if rev.nil?
            Utils::Git.last_revision_of_file(repo, repo/T.must(path))
          else
            File.read(files.fetch(0).realpath)
          end
          result = apply_common_transformations(result, remove_livecheck: false)
          dest_path = if args.no_shard?
            destination_tap.formula_dir/"#{base_name}.rb"
          else
            destination_tap.formula_dir/formula_shard(base_name)/"#{base_name}.rb"
          end
          write_to_path(result, dest_path)
          ohai "Copied #{name} to:", dest_path
          return
        end

        rev = T.let(nil, T.nilable(String))
        if args.version
          ohai "Searching repository history"
          version = args.version
          version_segments = Gem::Version.new(version).segments if Gem::Version.correct?(version)
          test_formula = T.let(nil, T.nilable(Formula))
          result = ""
          loop do
            rev = rev.nil? ? start_rev : "#{rev}~1"
            rev, (path,) = Utils::Git.last_revision_commit_of_files(repo, pattern, before_commit: rev)
            if rev.nil? && source_tap.shallow?
              odie <<~EOS
                Could not find #{name} but #{source_tap} is a shallow clone!
                Try again after running:
                  git -C "#{source_tap.path}" fetch --unshallow
              EOS
            elsif rev.nil?
              odie "Could not find #{name}! The formula or version may not have existed."
            end

            file = repo/T.must(path)
            result = Utils::Git.last_revision_of_file(repo, file, before_commit: rev)
            if result.empty?
              odebug "Skipping revision #{rev} - file is empty at this revision"
              next
            end

            test_formula = formula_at_revision(repo, name, file, rev)
            break if test_formula.nil? || test_formula.version == version

            if version_segments && Gem::Version.correct?(test_formula.version)
              test_formula_version_segments = Gem::Version.new(test_formula.version).segments
              if version_segments.length < test_formula_version_segments.length
                odebug "Apply semantic versioning with #{test_formula_version_segments}"
                break if version_segments == test_formula_version_segments.first(version_segments.length)
              end
            end

            odebug "Trying #{test_formula.version} from revision #{rev} against desired #{version}"
          end
          odie "Could not find #{name}! The formula or version may not have existed." if test_formula.nil?
        else
          # Search in the root directory of `repository` as well as recursively in all of its subdirectories.
          files = if start_rev == "HEAD"
            Dir[repo/"{,**/}"].filter_map do |dir|
              Pathname.glob("#{dir}/#{name}.rb").find(&:file?)
            end
          else
            []
          end

          if files.empty?
            ohai "Searching repository history"
            rev, (path,) = Utils::Git.last_revision_commit_of_files(repo, pattern, before_commit: start_rev)
            odie "Could not find #{name}! The formula or version may not have existed." if rev.nil?
            file = repo/T.must(path)
            version = T.must(formula_at_revision(repo, name, file, rev)).version
            result = Utils::Git.last_revision_of_file(repo, file)
          else
            file = files.fetch(0).realpath
            rev = T.let("HEAD", T.nilable(String))
            version = Formulary.factory(file).version
            result = File.read(file)
          end
        end

        # The class name has to be renamed to match the new filename,
        # e.g. Foo version 1.2.3 becomes FooAT123 and resides in Foo@1.2.3.rb.
        class_name = Formulary.class_s(name)

        # The version can only contain digits with decimals in between.
        version_string = version.to_s
                                .sub(/\D*(.+?)\D*$/, "\\1")
                                .gsub(/\D+/, ".")

        versioned_name = Formulary.class_s("#{base_name}@#{version_string}")
        result.sub!("class #{class_name} < Formula", "class #{versioned_name} < Formula")
        result = apply_common_transformations(result, remove_livecheck: !args.keep_livecheck?)

        dest_name = "#{base_name}@#{version_string}"
        dest_path = if args.no_shard?
          destination_tap.formula_dir/"#{dest_name}.rb"
        else
          destination_tap.formula_dir/formula_shard(base_name)/"#{dest_name}.rb"
        end
        write_to_path(result, dest_path)
        ohai "Writing formula for #{name} at #{version} from revision #{rev} to:", dest_path
      end

      sig { params(token: String, source_tap: Tap, destination_tap: Tap).void }
      def extract_cask_to_tap(token, source_tap, destination_tap)
        repo = source_tap.path
        start_rev = args.git_revision || "HEAD"
        base_token = token.sub(/\b@(.*)\z\b/i, "")
        pattern = if source_tap.core_cask_tap?
          [
            repo/"Casks"/cask_shard(base_token)/"#{base_token}.rb",
            repo/"Casks/#{base_token}.rb",
            repo/"Casks"/"**"/"#{base_token}.rb",
          ].uniq
        else
          [repo/"#{base_token}.rb", repo/"**/#{base_token}.rb"]
        end

        if args.unversioned?
          files = if start_rev == "HEAD"
            Dir[repo/"{,**/}"].filter_map do |dir|
              Pathname.glob("#{dir}/#{base_token}.rb").find(&:file?)
            end
          else
            []
          end
          result = if files.empty?
            rev, (path,) = Utils::Git.last_revision_commit_of_files(repo, pattern, before_commit: start_rev)
            odie "Could not find #{base_token}! The cask may not have existed." if rev.nil?
            Utils::Git.last_revision_of_file(repo, repo/T.must(path))
          else
            File.read(files.fetch(0).realpath)
          end
          result = apply_common_transformations(result, remove_livecheck: false)
          dest_path = if args.no_shard?
            destination_tap.cask_dir/"#{base_token}.rb"
          else
            destination_tap.cask_dir/cask_shard(base_token)/"#{base_token}.rb"
          end
          write_to_path(result, dest_path)
          ohai "Copied #{base_token} to:", dest_path
          return
        end

        rev = T.let(nil, T.nilable(String))
        version = T.let(nil, T.nilable(String))
        result = ""

        if args.version
          ohai "Searching repository history"
          target_version = args.version
          loop do
            rev = rev.nil? ? start_rev : "#{rev}~1"
            rev, (path,) = Utils::Git.last_revision_commit_of_files(repo, pattern, before_commit: rev)
            if rev.nil? && source_tap.shallow?
              odie <<~EOS
                Could not find #{base_token} but #{source_tap} is a shallow clone!
                Try again after running:
                  git -C "#{source_tap.path}" fetch --unshallow
              EOS
            elsif rev.nil?
              odie "Could not find #{base_token}! The cask or version may not have existed."
            end

            file = repo/T.must(path)
            result = Utils::Git.last_revision_of_file(repo, file, before_commit: rev)
            if result.empty?
              odebug "Skipping revision #{rev} - file is empty at this revision"
              next
            end

            version = cask_version_from_content(result)
            break if version == target_version

            odebug "Trying #{version} from revision #{rev} against desired #{target_version}"
          end
          odie "Could not find #{base_token}! The cask or version may not have existed." if version.nil?
        else
          files = if start_rev == "HEAD"
            Dir[repo/"{,**/}"].filter_map do |dir|
              Pathname.glob("#{dir}/#{base_token}.rb").find(&:file?)
            end
          else
            []
          end

          if files.empty?
            ohai "Searching repository history"
            rev, (path,) = Utils::Git.last_revision_commit_of_files(repo, pattern, before_commit: start_rev)
            odie "Could not find #{base_token}! The cask or version may not have existed." if rev.nil?
            file = repo/T.must(path)
            result = Utils::Git.last_revision_of_file(repo, file)
          else
            file = files.fetch(0).realpath
            rev = T.let("HEAD", T.nilable(String))
            result = File.read(file)
          end
          version = cask_version_from_content(result)
        end

        odie "Could not determine version for #{base_token}!" if version.nil?

        version_string = version.to_s
                                .sub(/\D*(.+?)\D*$/, "\\1")
                                .gsub(/\D+/, ".")

        result.sub!(/^cask "#{Regexp.escape(base_token)}" do/, "cask \"#{base_token}@#{version_string}\" do")
        result = apply_common_transformations(result, remove_livecheck: !args.keep_livecheck?)

        dest_name = "#{base_token}@#{version_string}"
        dest_path = if args.no_shard?
          destination_tap.cask_dir/"#{dest_name}.rb"
        else
          destination_tap.cask_dir/cask_shard(base_token)/"#{dest_name}.rb"
        end
        write_to_path(result, dest_path)
        ohai "Writing cask for #{base_token} at #{version} from revision #{rev} to:", dest_path
      end

      sig { params(result: String, remove_livecheck: T::Boolean).returns(String) }
      def apply_common_transformations(result, remove_livecheck:)
        result.sub!(BOTTLE_BLOCK_REGEX, "")
        result.sub!(LIVECHECK_BLOCK_REGEX, "") if remove_livecheck
        result.gsub!(/^(\s+)(deprecate!|disable!)/, '\1# \2') if args.remove_deprecations?
        result
      end

      sig { params(result: String, path: Pathname).void }
      def write_to_path(result, path)
        if path.exist?
          unless args.force?
            odie "Destination already exists: #{path}\nTo overwrite it and continue anyways, run with `--force`."
          end
          odebug "Overwriting existing file at #{path}"
          path.delete
        end
        path.dirname.mkpath
        path.write result
      end

      sig { params(content: String).returns(T.nilable(String)) }
      def cask_version_from_content(content)
        content.match(/^\s*version\s+"([^"]+)"/)&.captures&.first
      end

      sig { params(repo: Pathname, name: String, file: Pathname, rev: String).returns(T.nilable(Formula)) }
      def formula_at_revision(repo, name, file, rev)
        return if rev.empty?

        contents = Utils::Git.last_revision_of_file(repo, file, before_commit: rev)
        contents.gsub!("@url=", "url ")
        contents.gsub!("require 'brewkit'", "require 'formula'")
        contents.sub!(BOTTLE_BLOCK_REGEX, "")
        with_monkey_patch { Formulary.from_contents(name, file, contents, ignore_errors: true) }
      end

      sig { params(_block: T.proc.void).returns(T.untyped) }
      def with_monkey_patch(&_block)
        # Since `method_defined?` is not a supported type guard, the use of `alias_method` below is not typesafe:
        BottleSpecification.class_eval do
          T.unsafe(self).alias_method :old_method_missing, :method_missing if method_defined?(:method_missing)
          define_method(:method_missing) do |*_|
            # do nothing
          end
        end

        Module.class_eval do
          T.unsafe(self).alias_method :old_method_missing, :method_missing if method_defined?(:method_missing)
          define_method(:method_missing) do |*_|
            # do nothing
          end
        end

        Resource.class_eval do
          T.unsafe(self).alias_method :old_method_missing, :method_missing if method_defined?(:method_missing)
          define_method(:method_missing) do |*_|
            # do nothing
          end
        end

        DependencyCollector.class_eval do
          if method_defined?(:parse_symbol_spec)
            T.unsafe(self).alias_method :old_parse_symbol_spec,
                                        :parse_symbol_spec
          end
          define_method(:parse_symbol_spec) do |*_|
            # do nothing
          end
        end

        yield
      ensure
        BottleSpecification.class_eval do
          if method_defined?(:old_method_missing)
            T.unsafe(self).alias_method :method_missing, :old_method_missing
            T.unsafe(self).undef :old_method_missing
          end
        end

        Module.class_eval do
          if method_defined?(:old_method_missing)
            T.unsafe(self).alias_method :method_missing, :old_method_missing
            T.unsafe(self).undef :old_method_missing
          end
        end

        Resource.class_eval do
          if method_defined?(:old_method_missing)
            T.unsafe(self).alias_method :method_missing, :old_method_missing
            T.unsafe(self).undef :old_method_missing
          end
        end

        DependencyCollector.class_eval do
          if method_defined?(:old_parse_symbol_spec)
            T.unsafe(self).alias_method :parse_symbol_spec, :old_parse_symbol_spec
            T.unsafe(self).undef :old_parse_symbol_spec
          end
        end
      end
    end
  end
end
