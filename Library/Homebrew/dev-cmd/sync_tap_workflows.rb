# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "erb"
require "tap"
require "utils/curl"

module Homebrew
  module DevCmd
    class SyncTapWorkflows < AbstractCommand
      # Workflow files to fetch for cask taps.
      CASK_WORKFLOWS = T.let(%w[ci.yml ci-retry.yml actionlint.yml autobump.yml cache.yml].freeze,
                             T::Array[String])
      # Workflow files to fetch for formula taps.
      FORMULA_WORKFLOWS = T.let(%w[autobump.yml actionlint.yml cache.yml].freeze, T::Array[String])

      CASK_RAW_URL = T.let(
        "https://raw.githubusercontent.com/Homebrew/homebrew-cask/HEAD/.github/workflows",
        String,
      )
      CORE_RAW_URL = T.let(
        "https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/.github/workflows",
        String,
      )
      ORG_GITHUB_RAW_URL = T.let(
        "https://raw.githubusercontent.com/Homebrew/.github/HEAD/.github/workflows",
        String,
      )
      private_constant :CASK_WORKFLOWS, :FORMULA_WORKFLOWS, :CASK_RAW_URL, :CORE_RAW_URL, :ORG_GITHUB_RAW_URL

      cmd_args do
        usage_banner "`sync-tap-workflows` [<options>] <user>`/`<repo>"
        description <<~EOS
          Fetch and adapt upstream Homebrew CI workflow files for use in a third-party tap.
        EOS
        switch "--cask",
               description: "Sync cask CI workflows from Homebrew/homebrew-cask."
        switch "--formula",
               description: "Sync formula CI workflows from Homebrew/homebrew-core."
        flag   "--branch=",
               description: "Branch name for push triggers in workflows (default: `main`)."
        flag   "--bot-username=",
               description: "GitHub username for the automated bump bot (used in autobump.yml)."
        flag   "--bot-email=",
               description: "Commit email for the automated bump bot (used in autobump.yml)."
        switch "--dry-run", "-n",
               description: "Print what would be done rather than doing it."
        flag   "--pull-label=",
               description: "Label name for PR-pull workflows in publish.yml (default: `pr-pull`)."

        named_args :tap, number: 1
      end

      sig { override.void }
      def run
        Homebrew.install_bundler_gems!(groups: ["sync_workflows"])
        require "psych/pure"

        raise UsageError, "Either `--cask` or `--formula` must be specified." if !args.cask? && !args.formula?

        tap = args.named.to_taps.fetch(0)
        branch = args.branch || "main"
        bot_username = args.bot_username
        bot_email = args.bot_email
        workflows_dir = tap.path/".github/workflows"
        synced_paths = T.let([], T::Array[Pathname])

        if args.cask?
          CASK_WORKFLOWS.each do |filename|
            content = fetch_workflow(CASK_RAW_URL, filename)
            synced_paths << process_workflow(content, filename, tap,
                                             branch:, bot_username:, bot_email:, workflows_dir:)
          end
        end

        if args.formula?
          FORMULA_WORKFLOWS.each do |filename|
            base_url = case filename
            when "autobump.yml" then CORE_RAW_URL
            when "actionlint.yml" then ORG_GITHUB_RAW_URL
            else CASK_RAW_URL
            end
            content = fetch_workflow(base_url, filename)
            synced_paths << process_workflow(content, filename, tap,
                                             branch:, bot_username:, bot_email:, workflows_dir:)
          end

          label = args.pull_label || "pr-pull"
          {
            "tests.yml"   => render_tests_yml(branch:),
            "publish.yml" => render_publish_yml(branch:, label:),
          }.each do |filename, content|
            synced_paths << write_static_workflow(content, filename, workflows_dir:)
          end
        end

        action = args.dry_run? ? "Would sync" : "Synced"
        ohai "#{action} #{synced_paths.size} workflow file(s):"
        synced_paths.each { |path| puts "  #{path}" } unless synced_paths.empty?
      end

      private

      sig { params(base_url: String, filename: String).returns(String) }
      def fetch_workflow(base_url, filename)
        url = "#{base_url}/#{filename}"
        result = Utils::Curl.curl_output("--silent", "--fail", "--location", url)
        odie "Failed to fetch #{url}: #{result.stderr}" unless result.status.success?
        result.stdout
      end

      sig { params(content: String, filename: String, workflows_dir: Pathname).returns(Pathname) }
      def write_static_workflow(content, filename, workflows_dir:)
        output_path = workflows_dir/filename
        if args.dry_run?
          ohai "Would write #{output_path}"
          puts content
        else
          workflows_dir.mkpath
          output_path.write(content)
          ohai "Wrote #{output_path}"
        end
        output_path
      end

      sig { params(branch: String).returns(String) }
      def render_tests_yml(branch:)
        ERB.new(<<~ERB, trim_mode: "-").result(binding)
          name: brew test-bot

          on:
            push:
              branches:
                - <%= branch %>
            pull_request:

          jobs:
            test-bot:
              strategy:
                matrix:
                  os: [ ubuntu-22.04, macos-15-intel, macos-26 ]
              runs-on: ${{ matrix.os }}
              permissions:
                actions: read
                checks: read
                contents: read
                pull-requests: read
              steps:
                - name: Set up Homebrew
                  id: set-up-homebrew
                  uses: Homebrew/actions/setup-homebrew@main
                  with:
                    token: ${{ secrets.GITHUB_TOKEN }}

                - name: Cache Homebrew Bundler RubyGems
                  uses: actions/cache@v4
                  with:
                    path: ${{ steps.set-up-homebrew.outputs.gems-path }}
                    key: ${{ matrix.os }}-rubygems-${{ steps.set-up-homebrew.outputs.gems-hash }}
                    restore-keys: ${{ matrix.os }}-rubygems-

                - run: brew test-bot --only-cleanup-before

                - run: brew test-bot --only-setup

                - run: brew test-bot --only-tap-syntax

                - run: brew test-bot --only-formulae
                  if: github.event_name == 'pull_request'

                - name: Upload bottles as artifact
                  if: always() && github.event_name == 'pull_request'
                  uses: actions/upload-artifact@v4
                  with:
                    name: bottles_${{ matrix.os }}
                    path: '*.bottle.*'
        ERB
      end

      sig { params(branch: String, label: String).returns(String) }
      def render_publish_yml(branch:, label:)
        ERB.new(<<~ERB, trim_mode: "-").result(binding)
          name: brew pr-pull

          on:
            pull_request_target:
              types:
                - labeled

          jobs:
            pr-pull:
              if: contains(github.event.pull_request.labels.*.name, '<%= label %>')
              runs-on: ubuntu-22.04
              permissions:
                actions: read
                checks: read
                contents: write
                issues: read
                pull-requests: write
              steps:
                - name: Set up Homebrew
                  uses: Homebrew/actions/setup-homebrew@main
                  with:
                    token: ${{ secrets.GITHUB_TOKEN }}

                - name: Set up git
                  uses: Homebrew/actions/git-user-config@main

                - name: Pull bottles
                  env:
                    HOMEBREW_GITHUB_API_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                    PULL_REQUEST: ${{ github.event.pull_request.number }}
                  run: brew pr-pull --debug --tap="$GITHUB_REPOSITORY" "$PULL_REQUEST"

                - name: Push commits
                  uses: Homebrew/actions/git-try-push@main
                  with:
                    branch: <%= branch %>

                - name: Delete branch
                  if: github.event.pull_request.head.repo.fork == false
                  env:
                    BRANCH: ${{ github.event.pull_request.head.ref }}
                  run: git push --delete origin "$BRANCH"
        ERB
      end

      sig {
        params(
          content:       String,
          filename:      String,
          tap:           Tap,
          branch:        String,
          bot_username:  T.nilable(String),
          bot_email:     T.nilable(String),
          workflows_dir: Pathname,
        ).returns(Pathname)
      }
      def process_workflow(content, filename, tap, branch:, bot_username:, bot_email:, workflows_dir:)
        yaml = Psych::Pure.load(content, comments: true)

        apply_general_mutations!(yaml, tap, branch)
        apply_autobump_mutations!(yaml, bot_username, bot_email) if filename == "autobump.yml"

        output = Psych::Pure.dump(yaml)

        disabled = filename == "autobump.yml" && bot_username.nil? && bot_email.nil?
        output_filename = disabled ? "autobump.yml.disabled" : filename

        if disabled
          todo_comment = <<~COMMENT
            # TODO: Set BOT_TOKEN as a repository secret in
            # Settings → Secrets and variables → Actions → Secrets
            # Then set --bot-username and --bot-email and re-run, or rename this file
            # to autobump.yml after filling in the credentials below.
            # BOT_EMAIL format: <numeric_id>+username@users.noreply.github.com
          COMMENT
          output = todo_comment + output
        end

        output_path = workflows_dir/output_filename
        if args.dry_run?
          ohai "Would write #{output_path}"
          puts output
        else
          workflows_dir.mkpath
          output_path.write(output)
          ohai "Wrote #{output_path}"
        end
        output_path
      end

      sig { params(yaml: T.untyped, tap: Tap, branch: String).void }
      def apply_general_mutations!(yaml, tap, branch)
        return unless yaml.respond_to?(:each_value)

        on = yaml["on"] || yaml[true]
        if on.respond_to?(:dig)
          on["push"]["branches"] = [branch] if on.dig("push", "branches")
          on.delete("merge_group") if on.respond_to?(:key?) && on.key?("merge_group")
        end

        return unless yaml["jobs"].respond_to?(:each_value)

        yaml["jobs"].each_value do |job|
          next unless job.respond_to?(:each_value)

          job["if"] = adapt_condition(job["if"].to_s, tap) if job["if"].respond_to?(:gsub)

          next unless job["steps"].respond_to?(:to_ary)

          job["steps"].each do |step|
            next unless step.respond_to?(:each_value)

            step["if"] = adapt_condition(step["if"].to_s, tap) if step["if"].respond_to?(:gsub)

            step["run"] = adapt_run_script(step["run"].to_s, tap) if step["run"].respond_to?(:gsub)
          end
        end
      end

      sig { params(condition: String, tap: Tap).returns(String) }
      def adapt_condition(condition, tap)
        condition
          .gsub("github.repository_owner == 'Homebrew'", "github.repository_owner == '#{tap.user}'")
          .gsub("github.repository == 'Homebrew/homebrew-cask'", "github.repository == '#{tap.full_name}'")
          .gsub("github.repository == 'Homebrew/homebrew-core'", "github.repository == '#{tap.full_name}'")
          .gsub(" || github.event_name == 'merge_group'", "")
          .gsub("github.event_name == 'merge_group' || ", "")
      end

      sig { params(script: String, tap: Tap).returns(String) }
      def adapt_run_script(script, tap)
        script
          .gsub("${{ join(matrix.audit_args, ' ') }}", "--online --strict")
          .gsub("--tap=Homebrew/cask", "--tap=#{tap.user}/#{tap.repository}")
          .gsub("--tap=Homebrew/core", "--tap=#{tap.user}/#{tap.repository}")
          .then { |s| remove_merge_group_elif(s) }
      end

      sig { params(script: String).returns(String) }
      def remove_merge_group_elif(script)
        script.gsub(/\n\s*elif \[.*?merge_group.*?\].*?\n(?:.*\n)*?(?=\s*(?:elif|else|fi\b))/, "\n")
      end

      sig {
        params(
          yaml:         T.untyped,
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).void
      }
      def apply_autobump_mutations!(yaml, bot_username, bot_email)
        return unless yaml.respond_to?(:each_value)
        return unless yaml["jobs"].respond_to?(:each_value)

        yaml["jobs"].each_value do |job|
          next unless job.respond_to?(:each_value)

          if job["steps"].respond_to?(:to_ary)
            job["steps"].reject! do |step|
              step.respond_to?(:each_value) && step["name"].to_s.match?(/set up commit signing/i)
            end
          end

          adapt_env_hash!(job["env"], bot_username, bot_email) if job["env"].respond_to?(:each_key)

          next unless job["steps"].respond_to?(:to_ary)

          job["steps"].each do |step|
            next unless step.respond_to?(:each_value)

            adapt_env_hash!(step["env"], bot_username, bot_email) if step["env"].respond_to?(:each_key)
          end
        end
      end

      sig {
        params(
          env:          T.untyped,
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).void
      }
      def adapt_env_hash!(env, bot_username, bot_email)
        env.each_key do |key|
          val = env[key]
          next unless val.respond_to?(:gsub)

          new_val = val.gsub("secrets.HOMEBREW_CASK_REPO_WORKFLOW_TOKEN", "secrets.BOT_TOKEN")
                       .gsub("secrets.HOMEBREW_CORE_REPO_WORKFLOW_TOKEN", "secrets.BOT_TOKEN")
          new_val = new_val.gsub("BrewTestBot", bot_username) if bot_username
          new_val = new_val.gsub("1589480+BrewTestBot@users.noreply.github.com", bot_email) if bot_email
          env[key] = new_val
        end
      end
    end
  end
end
