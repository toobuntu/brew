# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "fileutils"
require "tap"
require "utils/curl"

module Homebrew
  module DevCmd
    # @api private
    class SyncTapWorkflows < AbstractCommand
      include FileUtils

      CASK_UPSTREAM = T.let("Homebrew/homebrew-cask", String)
      FORMULA_UPSTREAM = T.let("Homebrew/homebrew-core", String)
      CASK_WORKFLOWS = T.let(%w[ci.yml ci-retry.yml actionlint.yml autobump.yml cache.yml].freeze, T::Array[String])
      FORMULA_WORKFLOWS = T.let(%w[autobump.yml actionlint.yml cache.yml].freeze, T::Array[String])
      COMMIT_SIGNING_STEP = T.let(
        "\n      - name: Set up commit signing" \
        "\n        uses: Homebrew/actions/setup-commit-signing@main" \
        "\n        with:" \
        "\n          signing_key: ${{ secrets.BREWTESTBOT_SSH_SIGNING_KEY }}",
        String,
      )

      cmd_args do
        usage_banner "`sync-tap-workflows` [<options>] <user>`/`<repo>"
        description <<~EOS
          Fetch and adapt CI workflow files from an upstream Homebrew tap for use in a
          third-party tap. Workflow files are fetched from `Homebrew/homebrew-cask` (with
          `--cask`) or `Homebrew/homebrew-core` (with `--formula`) and adapted for the
          specified tap. Running the command again overwrites existing workflow files.
        EOS
        switch "--cask",
               description: "Sync cask CI workflows from `Homebrew/homebrew-cask`."
        switch "--formula",
               description: "Sync formula CI workflows from `Homebrew/homebrew-core`."
        flag   "--branch=",
               description: "Branch name for push triggers in workflows (default: `main`)."
        flag   "--bot-username=",
               description: "GitHub username for the automated bump bot (used in `autobump.yml`)."
        flag   "--bot-email=",
               description: "Commit email for the automated bump bot (used in `autobump.yml`)."
        switch "--dry-run", "-n",
               description: "Print what would be done rather than doing it."

        named_args :tap, number: 1
      end

      sig { override.void }
      def run
        odie "Specify either `--cask` or `--formula`." if !args.cask? && !args.formula?

        tap = args.named.to_taps.fetch(0)
        branch = args.branch || "main"

        sync_cask_workflows(tap, branch) if args.cask?
        sync_formula_workflows(tap, branch) if args.formula?
      end

      private

      sig { params(tap: Tap, branch: String).void }
      def sync_cask_workflows(tap, branch)
        bot_username = args.bot_username
        bot_email = args.bot_email
        CASK_WORKFLOWS.each do |filename|
          content = fetch_workflow(CASK_UPSTREAM, filename)
          adapted, output_filename = adapt_cask_workflow(filename, content, tap, branch, bot_username, bot_email)
          write_workflow(tap, output_filename, adapted)
        end
      end

      sig { params(tap: Tap, branch: String).void }
      def sync_formula_workflows(tap, branch)
        bot_username = args.bot_username
        bot_email = args.bot_email
        FORMULA_WORKFLOWS.each do |filename|
          content = fetch_workflow(FORMULA_UPSTREAM, filename)
          adapted, output_filename = adapt_formula_workflow(filename, content, tap, branch, bot_username, bot_email)
          write_workflow(tap, output_filename, adapted)
        end
      end

      sig { params(upstream: String, filename: String).returns(String) }
      def fetch_workflow(upstream, filename)
        url = "https://raw.githubusercontent.com/#{upstream}/HEAD/.github/workflows/#{filename}"
        result = Utils::Curl.curl_output("--location", "--fail", url)
        odie "Failed to fetch #{url}: #{result.stderr}" unless result.success?
        result.stdout
      end

      sig {
        params(
          filename:     String,
          content:      String,
          tap:          Tap,
          branch:       String,
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).returns([String, String])
      }
      def adapt_cask_workflow(filename, content, tap, branch, bot_username, bot_email)
        output_filename = filename
        adapted = case filename
        when "ci.yml"
          adapt_cask_ci(content, branch)
        when "actionlint.yml"
          adapt_actionlint(content, branch, tap.user)
        when "autobump.yml"
          output_filename = "autobump.yml.disabled" if !bot_username || !bot_email
          adapt_cask_autobump(content, tap, bot_username, bot_email)
        when "cache.yml"
          adapt_cache(content, tap.user)
        else
          content
        end
        [adapted, output_filename]
      end

      sig {
        params(
          filename:     String,
          content:      String,
          tap:          Tap,
          branch:       String,
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).returns([String, String])
      }
      def adapt_formula_workflow(filename, content, tap, branch, bot_username, bot_email)
        output_filename = filename
        adapted = case filename
        when "autobump.yml"
          output_filename = "autobump.yml.disabled" if !bot_username || !bot_email
          adapt_formula_autobump(content, tap, branch, bot_username, bot_email)
        when "actionlint.yml"
          adapt_actionlint(content, branch, tap.user)
        when "cache.yml"
          adapt_cache(content, tap.user)
        else
          content
        end
        [adapted, output_filename]
      end

      sig { params(content: String, branch: String).returns(String) }
      def adapt_cask_ci(content, branch)
        result = content.dup

        # Replace push branches with parameterized branch.
        result.gsub!(
          /^(  push:\n    branches:\n)      - main\n      - master\n/,
          "\\1      - #{branch}\n",
        )

        # Remove merge_group trigger (personal taps don't use merge queues).
        result.gsub!(/^  merge_group:\n/, "")

        # Remove "Run brew config" steps (diagnostic noise for third-party taps).
        result.gsub!("\n      - name: Run brew config\n        run: brew config\n", "")

        # Remove merge_group branch from generate-matrix script.
        result.gsub!(' || "${GITHUB_EVENT_NAME}" == "merge_group"', "")

        # Hardcode audit flags for third-party taps instead of using matrix.audit_args.
        result.gsub!("${{ join(matrix.audit_args, ' ') }}", "--online --strict")

        result
      end

      sig { params(content: String, branch: String, tap_user: String).returns(String) }
      def adapt_actionlint(content, branch, tap_user)
        result = content.dup

        # Replace push branches with parameterized branch.
        result.gsub!(
          /^(  push:\n    branches:\n)      - main\n      - master\n/,
          "\\1      - #{branch}\n",
        )

        # Replace Homebrew org guard with the tap owner.
        result.gsub!("github.repository_owner == 'Homebrew'", "github.repository_owner == '#{tap_user}'")

        # Remove merge_group reference from upload_sarif if condition.
        result.gsub!(" &&\n      github.event_name != 'merge_group'", "")

        result
      end

      sig {
        params(
          content:      String,
          tap:          Tap,
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).returns(String)
      }
      def adapt_cask_autobump(content, tap, bot_username, bot_email)
        result = content.dup

        tap_repo = "#{tap.user}/homebrew-#{tap.repository}"

        # Replace Homebrew repo guard with the tap's full repository name.
        result.gsub!("github.repository == 'Homebrew/homebrew-cask'", "github.repository == '#{tap_repo}'")

        # Remove "Set up commit signing" step (requires BrewTestBot SSH key).
        result.gsub!(COMMIT_SIGNING_STEP, "")

        # Replace Homebrew-specific API token secret.
        result.gsub!("secrets.HOMEBREW_CASK_REPO_WORKFLOW_TOKEN", "secrets.BOT_TOKEN")

        # Configure Git committer identity.
        if bot_username
          result.gsub!(
            "${{ (github.event_name == 'workflow_dispatch' && github.actor) || 'BrewTestBot' }}",
            bot_username,
          )
          result.gsub!("HOMEBREW_GIT_COMMITTER_NAME: BrewTestBot", "HOMEBREW_GIT_COMMITTER_NAME: #{bot_username}")
        else
          result.gsub!("HOMEBREW_GIT_COMMITTER_NAME: BrewTestBot",
                       "HOMEBREW_GIT_COMMITTER_NAME: # TODO: set bot username")
        end

        if bot_email
          result.gsub!(
            "HOMEBREW_GIT_COMMITTER_EMAIL: 1589480+BrewTestBot@users.noreply.github.com",
            "HOMEBREW_GIT_COMMITTER_EMAIL: #{bot_email}",
          )
        else
          result.gsub!(
            "HOMEBREW_GIT_COMMITTER_EMAIL: 1589480+BrewTestBot@users.noreply.github.com",
            "HOMEBREW_GIT_COMMITTER_EMAIL: # TODO: set bot email",
          )
        end

        # Replace upstream tap reference with this tap.
        result.gsub!("--auto --tap=Homebrew/cask", "--auto --tap=#{tap.user}/#{tap.repository}")

        result
      end

      sig {
        params(
          content:      String,
          tap:          Tap,
          branch:       String,
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).returns(String)
      }
      def adapt_formula_autobump(content, tap, branch, bot_username, bot_email)
        result = content.dup

        # Replace push branches with parameterized branch.
        result.gsub!(
          /^(  push:\n    branches:\n)      - main\n      - master\n/,
          "\\1      - #{branch}\n",
        )

        # Replace Homebrew org guard with the tap owner.
        result.gsub!("github.repository_owner == 'Homebrew'", "github.repository_owner == '#{tap.user}'")

        # Remove container block (personal taps don't have access to ghcr.io/homebrew images).
        result.gsub!("\n    container:\n      image: ghcr.io/homebrew/ubuntu22.04:main\n", "\n")

        # Remove job-level GNUPGHOME env (not needed outside Homebrew's infrastructure).
        result.gsub!("\n    env:\n      GNUPGHOME: /tmp/gnupghome\n", "\n")

        # Remove "Set up commit signing" step (requires BrewTestBot SSH key).
        result.gsub!(COMMIT_SIGNING_STEP, "")

        # Replace Homebrew-specific API token secret.
        result.gsub!("secrets.HOMEBREW_CORE_REPO_WORKFLOW_TOKEN", "secrets.BOT_TOKEN")

        # Configure Git committer identity.
        if bot_username
          result.gsub!(
            "${{ (github.event_name == 'workflow_dispatch' && github.actor) || 'BrewTestBot' }}",
            bot_username,
          )
          result.gsub!("HOMEBREW_GIT_COMMITTER_NAME: BrewTestBot", "HOMEBREW_GIT_COMMITTER_NAME: #{bot_username}")
        else
          result.gsub!("HOMEBREW_GIT_COMMITTER_NAME: BrewTestBot",
                       "HOMEBREW_GIT_COMMITTER_NAME: # TODO: set bot username")
        end

        if bot_email
          result.gsub!(
            "HOMEBREW_GIT_COMMITTER_EMAIL: 1589480+BrewTestBot@users.noreply.github.com",
            "HOMEBREW_GIT_COMMITTER_EMAIL: #{bot_email}",
          )
        else
          result.gsub!(
            "HOMEBREW_GIT_COMMITTER_EMAIL: 1589480+BrewTestBot@users.noreply.github.com",
            "HOMEBREW_GIT_COMMITTER_EMAIL: # TODO: set bot email",
          )
        end

        # Replace upstream tap reference with this tap.
        result.gsub!("--auto --tap=Homebrew/core", "--auto --tap=#{tap.user}/#{tap.repository}")

        result
      end

      sig { params(content: String, tap_user: String).returns(String) }
      def adapt_cache(content, tap_user)
        result = content.dup

        # Replace Homebrew org guard with the tap owner.
        result.gsub!("github.repository_owner == 'Homebrew'", "github.repository_owner == '#{tap_user}'")

        result
      end

      sig { params(tap: Tap, filename: String, content: String).void }
      def write_workflow(tap, filename, content)
        path = tap.path/".github"/"workflows"/filename
        if args.dry_run?
          ohai "Would write #{path}"
          puts content
        else
          (tap.path/".github"/"workflows").mkpath
          ohai "Writing #{path}"
          path.write content
        end
      end
    end
  end
end
