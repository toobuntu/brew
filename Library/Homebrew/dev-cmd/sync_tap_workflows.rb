# typed: strict
# frozen_string_literal: true

require "abstract_command"
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

        if args.cask?
          CASK_WORKFLOWS.each do |filename|
            content = fetch_workflow(CASK_RAW_URL, filename)
            process_workflow(content, filename, tap, branch:, bot_username:, bot_email:, workflows_dir:)
          end
        end

        return unless args.formula?

        FORMULA_WORKFLOWS.each do |filename|
          base_url = case filename
          when "autobump.yml" then CORE_RAW_URL
          when "actionlint.yml" then ORG_GITHUB_RAW_URL
          else CASK_RAW_URL
          end
          content = fetch_workflow(base_url, filename)
          process_workflow(content, filename, tap, branch:, bot_username:, bot_email:, workflows_dir:)
        end
      end

      private

      sig { params(base_url: String, filename: String).returns(String) }
      def fetch_workflow(base_url, filename)
        url = "#{base_url}/#{filename}"
        result = Utils::Curl.curl_output("--silent", "--fail", "--location", url)
        odie "Failed to fetch #{url}: #{result.stderr}" unless result.status.success?
        result.stdout
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
        ).void
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
      end

      sig { params(yaml: T.untyped, tap: Tap, branch: String).void }
      def apply_general_mutations!(yaml, tap, branch)
        return unless yaml.is_a?(Hash)

        on = yaml["on"]
        if on.is_a?(Hash)
          on["push"]["branches"] = [branch] if on.dig("push", "branches")
          on.delete("merge_group") if on.key?("merge_group")
        end

        return unless yaml["jobs"].is_a?(Hash)

        yaml["jobs"].each_value do |job|
          next unless job.is_a?(Hash)

          job["if"] = adapt_condition(job["if"], tap) if job["if"].is_a?(String)

          next unless job["steps"].is_a?(Array)

          job["steps"].each do |step|
            next unless step.is_a?(Hash)

            step["if"] = adapt_condition(step["if"], tap) if step["if"].is_a?(String)

            step["run"] = adapt_run_script(step["run"], tap) if step["run"].is_a?(String)
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
        return unless yaml.is_a?(Hash)
        return unless yaml["jobs"].is_a?(Hash)

        yaml["jobs"].each_value do |job|
          next unless job.is_a?(Hash)

          if job["steps"].is_a?(Array)
            job["steps"].reject! { |step| step.is_a?(Hash) && step["name"].to_s.match?(/set up commit signing/i) }
          end

          adapt_env_hash!(job["env"], bot_username, bot_email) if job["env"].is_a?(Hash)

          next unless job["steps"].is_a?(Array)

          job["steps"].each do |step|
            next unless step.is_a?(Hash)

            adapt_env_hash!(step["env"], bot_username, bot_email) if step["env"].is_a?(Hash)
          end
        end
      end

      sig {
        params(
          env:          T::Hash[String, T.untyped],
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).void
      }
      def adapt_env_hash!(env, bot_username, bot_email)
        env.transform_values! do |val|
          next val unless val.is_a?(String)

          val = val
                .gsub("secrets.HOMEBREW_CASK_REPO_WORKFLOW_TOKEN", "secrets.BOT_TOKEN")
                .gsub("secrets.HOMEBREW_CORE_REPO_WORKFLOW_TOKEN", "secrets.BOT_TOKEN")
          val = val.gsub("BrewTestBot", bot_username) if bot_username
          val = val.gsub("1589480+BrewTestBot@users.noreply.github.com", bot_email) if bot_email
          val
        end
      end
    end
  end
end
