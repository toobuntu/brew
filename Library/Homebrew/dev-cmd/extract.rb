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

      cmd_args do
        usage_banner "`extract` [`--version=`] [`--git-revision=`] [`--force`] [`--cask`] [`--formula`] " \
                     "[`--unversioned`] [`--no-quarantine`] <formula>|<cask> <tap>"
        description <<~EOS
          Look through repository history to find the most recent version of <formula> and
          create a copy in <tap>. Specifically, the command will create the new
          formula file at <tap>`/Formula/`<formula>`@`<version>`.rb`. If the tap is not
          installed yet, attempt to install/clone the tap before continuing. To extract
          a formula from a tap that is not `homebrew/core` use its fully-qualified form of
          <user>`/`<repo>`/`<formula>.
        EOS
        flag   "--git-revision=",
               description: "Search for the specified <version> of <formula> starting at <revision> instead of HEAD."
        flag   "--version=",
               description: "Extract the specified <version> of <formula> instead of the most recent."
        switch "-f", "--force",
               description: "Overwrite the destination formula if it already exists."
        switch "--formula", "--formulae",
               description: "Extract a formula (default if not a cask)."
        switch "--cask", "--casks",
               description: "Extract a cask instead of a formula."
        switch "--unversioned",
               description: "Copy the current cask to <tap> without appending a version suffix (cask only)."
        switch "--no-quarantine",
               description: "Add a postflight block to remove the quarantine attribute (cask only)."
        conflicts "--cask", "--formula"
        conflicts "--no-quarantine", "--formula"
        conflicts "--unversioned", "--formula"

        named_args [:formula, :cask, :tap], number: 2, without_api: true
      end

      sig { override.void }
      def run
        first_arg = args.named.fetch(0)

        # Determine if we're extracting a cask or a formula.
        if args.cask?
          extract_cask(first_arg)
        elsif args.formula?
          extract_formula(first_arg)
        elsif (tap_token = Tap.with_cask_token(first_arg))
          source_tap, token = tap_token
          if source_tap.installed? && source_tap.cask_files_by_name.key?(token)
            extract_cask(first_arg)
          else
            extract_formula(first_arg)
          end
        else
          # Default: try cask first for core cask tap, then fall back to formula.
          cask_tap = CoreCaskTap.instance
          if cask_tap.installed? && cask_tap.cask_files_by_name.key?(first_arg.downcase)
            extract_cask(first_arg)
          else
            extract_formula(first_arg)
          end
        end
      end

      private

      sig { params(name: String).void }
      def extract_formula(name)
        if (tap_with_name = Tap.with_formula_name(name))
          source_tap, name = tap_with_name
        else
          name = name.downcase
          source_tap = CoreTap.instance
        end
        raise TapFormulaUnavailableError.new(source_tap, name) unless source_tap.installed?

        destination_tap = Tap.fetch(args.named.fetch(1))
        unless Homebrew::EnvConfig.developer?
          odie "Cannot extract formula to homebrew/core!" if destination_tap.core_tap?
          odie "Cannot extract formula to homebrew/cask!" if destination_tap.core_cask_tap?
          odie "Cannot extract formula to the same tap!" if destination_tap == source_tap
        end
        destination_tap.install unless destination_tap.installed?

        repo = source_tap.path
        start_rev = args.git_revision || "HEAD"
        pattern = if source_tap.core_tap?
          [source_tap.new_formula_path(name), repo/"Formula/#{name}.rb"].uniq
        else
          [repo/"#{name}.rb", repo/"**/#{name}.rb"]
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

        class_name = Formulary.class_s(name)
        version_string = version.to_s
                                .sub(/\D*(.+?)\D*$/, "\\1")
                                .gsub(/\D+/, ".")
        name.sub!(/\b@(.*)\z\b/i, "")
        versioned_name = Formulary.class_s("#{name}@#{version_string}")
        result.sub!("class #{class_name} < Formula", "class #{versioned_name} < Formula")
        result.sub!(BOTTLE_BLOCK_REGEX, "")

        path = destination_tap.path/"Formula/#{name}@#{version_string}.rb"
        if path.exist?
          unless args.force?
            odie <<~EOS
              Destination formula already exists: #{path}
              To overwrite it and continue anyways, run:
                brew extract --force --version=#{version} #{name} #{destination_tap.name}
            EOS
          end
          odebug "Overwriting existing formula at #{path}"
          path.delete
        end
        ohai "Writing formula for #{name} at #{version} from revision #{rev} to:", path
        path.dirname.mkpath
        path.write result
      end

      sig { params(token_arg: String).void }
      def extract_cask(token_arg)
        if (tap_token = Tap.with_cask_token(token_arg))
          source_tap, token = tap_token
        else
          token = token_arg.downcase
          source_tap = CoreCaskTap.instance
        end
        raise TapFormulaUnavailableError.new(source_tap, token) unless source_tap.installed?

        destination_tap = Tap.fetch(args.named.fetch(1))
        unless Homebrew::EnvConfig.developer?
          odie "Cannot extract cask to homebrew/core!" if destination_tap.core_tap?
          odie "Cannot extract cask to homebrew/cask!" if destination_tap.core_cask_tap?
          odie "Cannot extract cask to the same tap!" if destination_tap == source_tap
        end
        destination_tap.install unless destination_tap.installed?

        if args.unversioned?
          copy_current_cask(token, source_tap, destination_tap)
        else
          extract_versioned_cask(token, source_tap, destination_tap)
        end
      end

      sig { params(token: String, source_tap: Tap, destination_tap: Tap).void }
      def extract_versioned_cask(token, source_tap, destination_tap)
        repo = source_tap.path
        start_rev = args.git_revision || "HEAD"
        pattern = if source_tap.core_cask_tap?
          [source_tap.new_cask_path(token), repo/"Casks/#{token}.rb"].uniq
        else
          [repo/"Casks/#{token}.rb", repo/"**/#{token}.rb"]
        end

        rev = T.let(nil, T.nilable(String))
        result = T.let("", String)
        version = T.let(args.version || "", String)

        if args.version
          ohai "Searching repository history"
          loop do
            rev = rev.nil? ? start_rev : "#{rev}~1"
            rev, (path,) = Utils::Git.last_revision_commit_of_files(repo, pattern, before_commit: rev)
            if rev.nil? && source_tap.shallow?
              odie <<~EOS
                Could not find #{token} but #{source_tap} is a shallow clone!
                Try again after running:
                  git -C "#{source_tap.path}" fetch --unshallow
              EOS
            elsif rev.nil?
              odie "Could not find #{token}! The cask or version may not have existed."
            end

            file = repo/T.must(path)
            result = Utils::Git.last_revision_of_file(repo, file, before_commit: rev)
            if result.empty?
              odebug "Skipping revision #{rev} - file is empty at this revision"
              next
            end

            current_version = result[/^\s*version\s+["']([^"']+)["']/, 1]
            break if current_version == version

            odebug "Trying version #{current_version.inspect} from revision #{rev} against desired #{version}"
          end
        else
          files = if start_rev == "HEAD"
            Dir[repo/"{,**/}"].filter_map do |dir|
              Pathname.glob("#{dir}/#{token}.rb").find(&:file?)
            end
          else
            []
          end

          if files.empty?
            ohai "Searching repository history"
            rev, (path,) = Utils::Git.last_revision_commit_of_files(repo, pattern, before_commit: start_rev)
            odie "Could not find #{token}! The cask or version may not have existed." if rev.nil?
            file = repo/T.must(path)
            result = Utils::Git.last_revision_of_file(repo, file)
          else
            file = files.fetch(0).realpath
            rev = T.let("HEAD", T.nilable(String))
            result = File.read(file)
          end
          version = result[/^\s*version\s+["']([^"']+)["']/, 1] || ""
          odie "Could not determine version for #{token}!" if version.empty?
        end

        version_string = version.sub(/\D*(.+?)\D*$/, "\\1").gsub(/\D+/, ".")
        token.sub!(/\b@(.*)\z\b/i, "")
        versioned_token = "#{token}@#{version_string}"
        result.sub!(/^(cask\s+["'])#{Regexp.escape(token)}(["']\s+do)/, "\\1#{versioned_token}\\2")

        result = add_quarantine_postflight(result) if args.no_quarantine?

        path = destination_tap.path/"Casks/#{versioned_token}.rb"
        if path.exist?
          unless args.force?
            odie <<~EOS
              Destination cask already exists: #{path}
              To overwrite it and continue anyways, run:
                brew extract --force --cask --version=#{version} #{token} #{destination_tap.name}
            EOS
          end
          odebug "Overwriting existing cask at #{path}"
          path.delete
        end
        ohai "Writing cask for #{token} at #{version} from revision #{rev} to:", path
        path.dirname.mkpath
        path.write result
      end

      sig { params(token: String, source_tap: Tap, destination_tap: Tap).void }
      def copy_current_cask(token, source_tap, destination_tap)
        cask_file = source_tap.cask_files_by_name[token]
        odie "Could not find cask #{token} in #{source_tap}!" if cask_file.nil?

        result = File.read(cask_file)
        result = add_quarantine_postflight(result) if args.no_quarantine?

        path = destination_tap.new_cask_path(token)
        if path.exist?
          unless args.force?
            odie <<~EOS
              Destination cask already exists: #{path}
              To overwrite it and continue anyways, run:
                brew extract --force --cask --unversioned #{token} #{destination_tap.name}
            EOS
          end
          odebug "Overwriting existing cask at #{path}"
          path.delete
        end
        ohai "Writing cask for #{token} to:", path
        path.dirname.mkpath
        path.write result
      end

      sig { params(content: String).returns(String) }
      def add_quarantine_postflight(content)
        if content.include?("com.apple.quarantine")
          opoo "Existing postflight block already handles quarantine"
          return content
        end

        apps = content.scan(/^\s*app\s+["']([^"']+)["']/).flatten
        if apps.empty?
          opoo "No app stanza found; you may need to handle quarantine removal manually."
          return content
        end

        xattr_commands = apps.map do |app|
          [
            "    system_command \"/usr/bin/xattr\",",
            "                   args: [\"-dr\", \"com.apple.quarantine\", \"\#{appdir}/#{app}\"],",
            "                   sudo: false",
          ].join("\n")
        end.join("\n")

        postflight_block = "\n  postflight do\n#{xattr_commands}\n  end\n"

        opoo <<~EOS
          A postflight block has been added to remove the quarantine attribute.
          This bypasses macOS Gatekeeper for this cask. You are responsible for
          verifying the safety of this software.
        EOS

        content.sub(/^end\s*\z/, "#{postflight_block}end\n")
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
