# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "erb"
require "fileutils"
require "tap"
require "utils/uid"

module Homebrew
  module DevCmd
    # `tap-new` generates scaffolding for a new Homebrew tap.
    class TapNew < AbstractCommand
      include FileUtils

      cmd_args do
        usage_banner "`tap-new` [<options>] <user>`/`<repo>"
        description <<~EOS
          Generate the template files for a new tap.
        EOS
        switch "--no-git",
               description: "Don't initialize a Git repository for the tap."
        switch "--formula",
               description: "Explicitly generate formula tap scaffolding (Formula/ directory, bottle workflows). " \
                            "This is the default if neither `--formula` nor `--cask` is specified."
        switch "--cask",
               description: "Generate cask tap scaffolding (Casks/ directory, cask CI workflows)."
        flag   "--pull-label=",
               description: "Label name for pull requests ready to be pulled. When a PR with this label " \
                            "is created, the `publish.yml` workflow triggers `brew pr-pull` to merge " \
                            "bottles into the tap (default: `pr-pull`). Only used for formula taps."
        flag   "--branch=",
               description: "Initialize Git repository and setup GitHub Actions workflows with the " \
                            "specified branch name (default: `main`)."
        flag   "--bot-username=",
               description: "GitHub username for the automated bump bot (used in autobump.yml)."
        flag   "--bot-email=",
               description: "Commit email for the automated bump bot, e.g. " \
                            "\"12345+bot@users.noreply.github.com\" (used in autobump.yml)."
        switch "--github-packages",
               description: "Upload bottles to GitHub Packages."

        named_args :tap, number: 1
      end

      sig { override.void }
      def run
        label = args.pull_label || "pr-pull"
        branch = args.branch || "main"

        tap = args.named.to_taps.fetch(0)
        odie "Invalid tap name '#{tap}'" unless tap.path.to_s.match?(HOMEBREW_TAP_PATH_REGEX)
        odie "Tap is already installed!" if tap.installed?

        odie "`--github-packages` requires `--formula` (bottles are a formula concept)." \
          if args.github_packages? && args.cask? && !args.formula?

        titleized_user = tap.user.dup
        titleized_repository = tap.repository.dup
        titleized_user[0] = T.must(titleized_user[0]).upcase
        titleized_repository[0] = T.must(titleized_repository[0]).upcase
        # Duplicate assignment to silence `assigned but unused variable` warning
        root_url = root_url = GitHubPackages.root_url(tap.user, "homebrew-#{tap.repository}") if args.github_packages?
        bot_username = args.bot_username
        bot_email = args.bot_email

        generate_formula = args.formula? || !args.cask?
        generate_cask = args.cask?
        explicit_flags = args.formula? || args.cask?
        has_bot_creds = !bot_username.nil? && !bot_email.nil?

        (tap.path/"Formula").mkpath if generate_formula
        (tap.path/"Casks").mkpath if generate_cask

        write_path(tap, "README.md", readme_content(tap, titleized_user, titleized_repository,
                                                    generate_formula, generate_cask))

        (tap.path/".github/workflows").mkpath

        formula_files = if generate_formula
          formula_workflow_files(branch, label, root_url, tap, bot_username, bot_email)
        else
          {}
        end

        if explicit_flags
          cask_files = generate_cask ? cask_workflow_files(branch, tap, bot_username, bot_email) : {}

          if generate_formula && generate_cask
            %w[autobump.yml autobump.yml.disabled].each do |key|
              if formula_files.key?(key)
                suffix = key.end_with?(".disabled") ? ".disabled" : ""
                formula_files["autobump-formulae.yml#{suffix}"] = T.must(formula_files.delete(key))
              end
              if cask_files.key?(key)
                suffix = key.end_with?(".disabled") ? ".disabled" : ""
                cask_files["autobump-casks.yml#{suffix}"] = T.must(cask_files.delete(key))
              end
            end
          end

          workflow_files = formula_files.merge(cask_files).merge(shared_workflow_files(branch, tap))
          workflow_files.each do |filename, content|
            write_path(tap, ".github/workflows/#{filename}", content)
          end

          write_path(tap, ".github/autobump.txt", autobump_txt_content)
        else
          # Default behaviour: write only tests.yml and publish.yml for backward compatibility
          %w[tests.yml publish.yml].each do |filename|
            write_path(tap, ".github/workflows/#{filename}", T.must(formula_files[filename]))
          end
        end

        unless args.no_git?
          cd tap.path do |path|
            Utils::Git.set_name_email!
            Utils::Git.setup_gpg!

            # Would be nice to use --initial-branch here but it's not available in
            # older versions of Git that we support.
            safe_system "git", "-c", "init.defaultBranch=#{branch}", "init"

            args = []
            git_owner = File.stat(File.join(path, ".git")).uid
            if git_owner != Process.uid && git_owner == Process.euid
              # Under Homebrew user model, EUID is permitted to execute commands under the UID.
              # Root users are never allowed (see brew.sh).
              args << "-c" << "safe.directory=#{path}"
            end

            # Use the configuration of the original user, which will have author information and signing keys.
            Utils::UID.drop_euid do
              env = { HOME: Utils::UID.uid_home }.compact
              env[:TMPDIR] = nil if (tmpdir = ENV.fetch("TMPDIR", nil)) && !File.writable?(tmpdir)
              with_env(env) do
                safe_system "git", *args, "add", "--all"
                safe_system "git", *args, "commit", "-m", "Create #{tap} tap"
                safe_system "git", *args, "branch", "-m", branch
              end
            end
          end
        end

        ohai "Created #{tap}"
        if generate_formula && generate_cask
          puts <<~EOS
            #{tap.path}

            For formulae: label your PR as `#{label}` to trigger bottle publishing.
            For casks: merge directly once CI passes.
          EOS
        elsif generate_cask
          puts <<~EOS
            #{tap.path}

            When a pull request making changes to a cask becomes green
            (all checks passed), you can merge it directly.
          EOS
        else
          puts <<~EOS
            #{tap.path}

            When a pull request making changes to a formula (or formulae) becomes green
            (all checks passed), then you can publish the built bottles.
            To do so, label your PR as `#{label}` and the workflow will be triggered.
          EOS
        end

        return if !explicit_flags || has_bot_creds

        puts <<~EOS
          To enable automatic version bumping:
          1. Create a GitHub personal access token with appropriate permissions
          2. Add it as a repository secret named BOT_TOKEN
          3. Set --bot-username and --bot-email, or rename autobump.yml.disabled
          4. Add package names to .github/autobump.txt
        EOS
      end

      private

      sig {
        params(
          branch:       String,
          label:        String,
          root_url:     T.nilable(String),
          tap:          Tap,
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).returns(T::Hash[String, String])
      }
      def formula_workflow_files(branch, label, root_url, tap, bot_username, bot_email)
        tests_yml = <<~ERB
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
          <% if root_url -%>
                packages: read
          <% end -%>
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
          <% if root_url -%>
                - name: Base64-encode GITHUB_TOKEN for HOMEBREW_DOCKER_REGISTRY_TOKEN
                  id: base64-encode
                  if: github.event_name == 'pull_request'
                  env:
                    TOKEN: ${{ secrets.GITHUB_TOKEN }}
                  run: |
                    base64_token=$(echo -n "${TOKEN}" | base64 | tr -d "\\n")
                    echo "::add-mask::${base64_token}"
                    echo "token=${base64_token}" >> "${GITHUB_OUTPUT}"
          <% end -%>
                - run: brew test-bot --only-formulae#{" --root-url=#{root_url}" if root_url}
                  if: github.event_name == 'pull_request'
          <% if root_url -%>
                  env:
                    HOMEBREW_DOCKER_REGISTRY_TOKEN: ${{ steps.base64-encode.outputs.token }}
          <% end -%>

                - name: Upload bottles as artifact
                  if: always() && github.event_name == 'pull_request'
                  uses: actions/upload-artifact@v4
                  with:
                    name: bottles_${{ matrix.os }}
                    path: '*.bottle.*'
        ERB

        publish_yml = <<~ERB
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
          <% if root_url -%>
                packages: write
          <% end -%>
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
          <% if root_url -%>
                    HOMEBREW_GITHUB_PACKAGES_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                    HOMEBREW_GITHUB_PACKAGES_USER: ${{ github.repository_owner }}
          <% end -%>
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

        autobump_disabled = bot_username.nil? || bot_email.nil?
        autobump_prefix = autobump_disabled ? <<~COMMENT : ""
          # TODO: Configure the bot before enabling this workflow:
          # 1. Create a GitHub personal access token with appropriate permissions
          # 2. Add it as a repository secret named BOT_TOKEN
          # 3. Rename this file to autobump.yml
          # 4. Add formula names to .github/autobump.txt
          #
        COMMENT

        autobump_yml = <<~ERB
          <%= autobump_prefix -%>
          name: Bump formulae on schedule or request

          on:
            workflow_dispatch:
              inputs:
                formulae:
                  description: Custom list of formulae to livecheck and bump if outdated
                  required: false
            schedule:
              # Every 3 hours from 1 through 23 with an offset of 45 minutes
              - cron: "45 1-23/3 * * *"

          permissions:
            contents: read

          defaults:
            run:
              shell: bash -xeuo pipefail {0}

          jobs:
            autobump:
              if: github.repository == '<%= tap.user %>/homebrew-<%= tap.repository %>'
              runs-on: macos-latest
              steps:
                - name: Set up Homebrew
                  id: set-up-homebrew
                  uses: Homebrew/actions/setup-homebrew@main
                  with:
                    core: true
                    cask: false

                - name: Configure Git user
                  uses: Homebrew/actions/git-user-config@main
                  with:
                    username: <%= bot_username || 'BrewTestBot' %>

                - name: Bump formulae
                  env:
                    HOMEBREW_TEST_BOT_AUTOBUMP: 1
                    HOMEBREW_GITHUB_API_TOKEN: ${{ secrets.BOT_TOKEN }}
                    HOMEBREW_GIT_COMMITTER_NAME: <%= bot_username || 'TODO: set HOMEBREW_GIT_COMMITTER_NAME' %>
                    HOMEBREW_GIT_COMMITTER_EMAIL: <%= bot_email || 'TODO: set HOMEBREW_GIT_COMMITTER_EMAIL' %>
                    FORMULAE: ${{ inputs.formulae }}
                  run: |
                    BREW_BUMP=(brew bump --no-fork --open-pr --formulae)
                    if [[ -n "${FORMULAE-}" ]]; then
                      xargs -t "${BREW_BUMP[@]}" <<<"${FORMULAE}"
                    else
                      "${BREW_BUMP[@]}" --auto --tap=<%= tap.user %>/<%= tap.repository %>
                    fi
        ERB

        autobump_key = autobump_disabled ? "autobump.yml.disabled" : "autobump.yml"

        {
          "tests.yml"   => ERB.new(tests_yml, trim_mode: "-").result(binding),
          "publish.yml" => ERB.new(publish_yml, trim_mode: "-").result(binding),
          autobump_key  => ERB.new(autobump_yml, trim_mode: "-").result(binding),
        }
      end

      sig {
        params(
          branch:       String,
          tap:          Tap,
          bot_username: T.nilable(String),
          bot_email:    T.nilable(String),
        ).returns(T::Hash[String, String])
      }
      def cask_workflow_files(branch, tap, bot_username, bot_email)
        ci_yml = <<~'ERB'
          name: CI

          on:
            push:
              branches:
                - <%= branch %>
            pull_request:
            workflow_dispatch:
              inputs:
                casks:
                  description: List of casks to audit (comma-separated)
                  required: true
                skip_install:
                  description: Skip installation of casks
                  required: false
                  default: true
                  type: boolean
                new_cask:
                  description: Apply new cask audit
                  required: false
                  default: false
                  type: boolean

          env:
            HOMEBREW_DEVELOPER: 1
            HOMEBREW_NO_AUTO_UPDATE: 1
            HOMEBREW_NO_INSTALL_FROM_API: 1
            HOMEBREW_GITHUB_API_TOKEN: ${{ github.token }}

          concurrency:
            group: "${{ github.ref }}"
            cancel-in-progress: ${{ github.event_name == 'pull_request' }}

          permissions:
            contents: read

          jobs:
            generate-matrix:
              outputs:
                matrix: ${{ steps.generate-matrix.outputs.matrix }}
              runs-on: macos-latest
              steps:
                - name: Set up Homebrew
                  id: set-up-homebrew
                  uses: Homebrew/actions/setup-homebrew@main
                  with:
                    core: false
                    cask: true

                - name: Check out Pull Request
                  uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
                  with:
                    fetch-depth: 0
                    persist-credentials: false

                - name: Generate CI matrix
                  id: generate-matrix
                  env:
                    INPUT_CASKS: ${{ github.event.inputs.casks }}
                    PULL_REQUEST_URL: ${{ github.event.pull_request.url }}
                  run: |
                    if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]
                    then
                      # shellcheck disable=SC2086 # $INPUT_CASKS is a space-separated list of cask tokens
                      brew generate-cask-ci-matrix ${{ github.event.inputs.skip_install && '--skip-install' }} ${{ github.event.inputs.new_cask && '--new' }} --casks $INPUT_CASKS
                    elif [[ "${GITHUB_EVENT_NAME}" == "push" ]]
                    then
                      brew generate-cask-ci-matrix --syntax-only
                    else
                      brew generate-cask-ci-matrix --url "$PULL_REQUEST_URL"
                    fi

            test:
              name: ${{ matrix.name }}
              needs: generate-matrix
              runs-on: ${{ matrix.runner }}
              container: ${{ matrix.container || null }}
              strategy:
                fail-fast: false
                matrix:
                  include: ${{ fromJson(needs.generate-matrix.outputs.matrix) }}
              steps:
                - name: Set up Homebrew
                  id: set-up-homebrew
                  uses: Homebrew/actions/setup-homebrew@main
                  with:
                    core: true
                    cask: true

                - name: Enable debug mode
                  run: |
                    echo 'HOMEBREW_DEBUG=1' >> "${GITHUB_ENV}"
                    echo 'HOMEBREW_VERBOSE=1' >> "${GITHUB_ENV}"
                  if: runner.debug

                - name: Check out Pull Request
                  uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
                  with:
                    fetch-depth: 0
                    persist-credentials: false

                - name: Clean up CI machine
                  if: runner.os == 'macOS'
                  run: brew test-bot --cleanup --only-cleanup-before

                - name: Cache Homebrew Gems
                  id: cache
                  uses: actions/cache@cdf6c1fa76f9f475f3d7449005a359c84ca0f306 # v5.0.3
                  with:
                    path: ${{ steps.set-up-homebrew.outputs.gems-path }}
                    key: ${{ matrix.runner }}-rubygems-${{ steps.set-up-homebrew.outputs.gems-hash }}
                    restore-keys: ${{ matrix.runner }}-rubygems-

                - name: Cache style cache
                  if: runner.os == 'macOS'
                  uses: actions/cache@cdf6c1fa76f9f475f3d7449005a359c84ca0f306 # v5.0.3
                  with:
                    path: ~/Library/Caches/Homebrew/style
                    key: macos-style-cache-${{ github.sha }}
                    restore-keys: macos-style-cache-

                - name: Run brew test-bot --only-tap-syntax
                  id: tap-syntax
                  run: brew test-bot --tap '${{ matrix.tap }}' --only-tap-syntax
                  if: always() && !matrix.cask

                - name: Run brew fetch --cask ${{ matrix.cask.token }}
                  id: fetch
                  run: |
                    brew fetch --cask --retry --force ${{ join(matrix.fetch_args, ' ') }} '${{ matrix.cask.path }}'
                  timeout-minutes: 30
                  if: >
                    always() &&
                    contains(fromJSON('["success", "skipped"]'), steps.tap-syntax.outcome) &&
                    matrix.cask

                - name: Run brew audit --cask${{ (matrix.cask && ' ') || ' --tap ' }}${{ matrix.cask.token || matrix.tap }}
                  id: audit
                  run: |
                    brew audit --cask --online --strict${{ (matrix.cask && ' ') || ' --tap ' }}'${{ matrix.cask.token || matrix.tap }}'
                  timeout-minutes: 30
                  if: >
                    always() &&
                    contains(fromJSON('["success", "skipped"]'), steps.tap-syntax.outcome) &&
                    (!matrix.cask || steps.fetch.outcome == 'success') &&
                    !matrix.skip_audit

                - name: Gather cask information
                  id: info
                  run: |
                    brew ruby <<'EOF'
                      require 'cask/cask_loader'
                      require 'cask/installer'

                      cask = Cask::CaskLoader.load('${{ matrix.cask.path }}')

                      manual_installer = cask.artifacts.any? do |artifact|
                        if defined?(artifact.manual_install)
                          artifact.manual_install
                        end
                      end

                      macos_requirement_satisfied = if macos_requirement = cask.depends_on.macos
                        macos_requirement.satisfied?
                      else
                        true
                      end

                      cask_conflicts = cask.conflicts_with&.dig(:cask).to_a.select { |c| Cask::CaskLoader.load(c).installed? }
                      formula_conflicts = cask.conflicts_with&.dig(:formula).to_a.select { |f| Formula[f].any_version_installed? }

                      installer = Cask::Installer.new(cask)
                      cask_and_formula_dependencies = installer.missing_cask_and_formula_dependencies

                      cask_dependencies = cask_and_formula_dependencies.select { |d| d.is_a?(Cask::Cask) }.map(&:full_name)
                      formula_dependencies = cask_and_formula_dependencies.select { |d| d.is_a?(Formula) }.map(&:full_name)

                      File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |f|
                        f.puts "manual_installer=#{JSON.generate(manual_installer)}"
                        f.puts "macos_requirement_satisfied=#{JSON.generate(macos_requirement_satisfied)}"
                        f.puts "formula_dependencies=#{JSON.generate(formula_dependencies)}"
                      end

                      File.open(ENV.fetch("GITHUB_ENV"), "a") do |f|
                        f.puts "CASK_CONFLICTS=#{cask_conflicts&.join(" ")}" if cask_conflicts.present?
                        f.puts "CASK_DEPENDENCIES=#{cask_dependencies&.join(" ")}" if cask_dependencies.present?
                        f.puts "FORMULA_CONFLICTS=#{formula_conflicts&.join(" ")}" if formula_conflicts.present?
                      end
                    EOF
                  if: always() && steps.fetch.outcome == 'success' && matrix.cask

                - name: Uninstall conflicting formulae
                  run: |
                    read -r -a formula_conflicts_array <<< "$FORMULA_CONFLICTS"
                    brew uninstall --formula "${formula_conflicts_array[@]}"
                  if: ${{ always() && steps.info.outcome == 'success' && env.FORMULA_CONFLICTS != '' }}
                  timeout-minutes: 30

                - name: Uninstall conflicting casks
                  run: |
                    read -r -a cask_conflicts_array <<< "$CASK_CONFLICTS"
                    brew uninstall --cask "${cask_conflicts_array[@]}"
                  if: ${{ always() && steps.info.outcome == 'success' && env.CASK_CONFLICTS != '' }}
                  timeout-minutes: 30

                - name: Run brew uninstall --cask --force --zap ${{ matrix.cask.token }}
                  run: |
                    brew uninstall --cask --force --zap '${{ matrix.cask.path }}'
                  if: always() && steps.info.outcome == 'success'
                  timeout-minutes: 30

                - name: Take snapshot of installed and running apps and services (macOS only)
                  id: snapshot
                  run: |
                    brew ruby -r "$(brew --repository homebrew/cask)/cmd/lib/check.rb" <<'EOF'
                      File.open(ENV.fetch("GITHUB_ENV"), "a") do |f|
                        # We have to use a `HOMEBREW_` prefix so it will survive the
                        # environment variable filtering in `brew`.
                        f.puts "HOMEBREW_SNAPSHOT_BEFORE=#{JSON.generate(Check.all)}"
                      end
                    EOF
                  if: always() && steps.info.outcome == 'success' && runner.os == 'macOS'

                - name: Run brew install --cask ${{ matrix.cask.token }}
                  id: install
                  run: brew install --cask '${{ matrix.cask.path }}'
                  if: >
                    always() && steps.info.outcome == 'success' &&
                    fromJSON(steps.info.outputs.macos_requirement_satisfied) &&
                    !matrix.skip_install
                  timeout-minutes: 30

                - name: Run brew uninstall --cask ${{ matrix.cask.token }}
                  run: brew uninstall --cask '${{ matrix.cask.path }}'
                  if: always() && steps.install.outcome == 'success' && !fromJSON(steps.info.outputs.manual_installer)
                  timeout-minutes: 30

                - name: Uninstall cask dependencies
                  run: |
                    read -r -a cask_dependencies_array <<< "$CASK_DEPENDENCIES"
                    brew uninstall --cask "${cask_dependencies_array[@]}"
                  if: ${{ always() && steps.install.outcome == 'success' && env.CASK_DEPENDENCIES != '' }}
                  timeout-minutes: 30

                - name: Compare installed and running apps and services with snapshot (macOS only)
                  run: |
                    brew ruby -r "$(brew --repository homebrew/cask)/cmd/lib/check.rb" <<'EOF'
                      require "cask/cask_loader"
                      require "utils/github/actions"

                      before = JSON.parse(ENV.fetch("HOMEBREW_SNAPSHOT_BEFORE", "{}"))
                                   .transform_keys(&:to_sym)
                      after = Check.all

                      cask = Cask::CaskLoader.load('${{ matrix.cask.path }}')
                      errors = Check.errors(before, after, cask: cask)

                      errors.each do |error|
                        puts GitHub::Actions::Annotation.new(:error, error, file: '${{ matrix.cask.path }}')
                      end

                      exit 1 if errors.any?
                    EOF
                  if: always() && steps.snapshot.outcome == 'success' && steps.install.outcome == 'success' && runner.os == 'macOS'

            conclusion:
              name: conclusion
              needs: test
              runs-on: ubuntu-slim
              if: always()
              steps:
                - name: Result
                  run: ${{ needs.test.result == 'success' }}
        ERB

        ci_retry_yml = <<~'YAML'
          name: CI Retry Failed Jobs

          on:
            schedule:
              - cron: "0 */1 * * *"
            workflow_dispatch:

          permissions:
            contents: read
            pull-requests: read
            actions: write

          concurrency:
            group: ci-retry
            cancel-in-progress: false

          jobs:
            retry-failed:
              name: Re-run failed jobs for labeled PRs
              runs-on: ubuntu-slim
              timeout-minutes: 10
              steps:
                - name: Re-run failed jobs
                  env:
                    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                    REPO: ${{ github.repository }}
                  run: |
                    set -euo pipefail

                    # Get PRs with ci-retry label and process them
                    prs_json="$(gh pr list --repo "$REPO" --label ci-retry --state open --json number,headRefName,headRefOid)" || {
                      echo "Failed to fetch PRs with ci-retry label" >&2; exit 1
                    }

                    if [[ "$(jq length <<< "$prs_json")" -eq 0 ]]; then
                      echo "No open PRs with label ci-retry."; exit 0
                    fi

                    # Process each PR
                    jq -r '.[] | "\(.number) \(.headRefName) \(.headRefOid)"' <<< "$prs_json" | while IFS=' ' read -r pr_number head_ref head_sha; do
                      echo "Processing PR #$pr_number (ref: $head_ref sha: $head_sha)"

                      # Get runs for this branch
                      runs_json="$(gh run list --repo "$REPO" --branch "$head_ref" --limit 20 \
                        --json databaseId,headSha,status,conclusion)" || {
                        echo "  Failed to fetch runs for PR #$pr_number" >&2; continue
                      }

                      # Filter runs by commit SHA
                      filtered_by_sha="$(jq --arg sha "$head_sha" '.[] | select(.headSha==$sha)' <<< "$runs_json")"

                      # Check if there are any currently running or queued runs for this commit
                      running_runs="$(jq 'select(.status=="in_progress" or .status=="queued") | .databaseId' <<< "$filtered_by_sha")"

                      if [[ -n "$running_runs" ]]; then
                        echo "  Skipping rerun - found running/queued jobs for PR #$pr_number (commit: $head_sha)"
                        continue
                      fi

                      # Filter by completed status
                      filtered_by_status="$(jq 'select(.status=="completed")' <<< "$filtered_by_sha")"

                      # Filter by failed/cancelled/timed out conclusion and get latest run only
                      latest_failed_run="$(jq 'select(.conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out") | .databaseId' <<< "$filtered_by_status" | head -n 1)"

                      if [[ -z "$latest_failed_run" ]]; then
                        echo "  No failed/cancelled runs to retry for PR #$pr_number."
                        continue
                      fi

                      # Retry the latest failed run only
                      echo "  Re-running failed jobs for latest run $latest_failed_run"
                      if gh run rerun --repo "$REPO" "$latest_failed_run" --failed >/dev/null 2>&1; then
                        echo "    Rerun requested."
                      else
                        echo "    Failed to request rerun for $latest_failed_run" >&2
                      fi
                    done

                    echo "Done."
        YAML

        autobump_disabled = bot_username.nil? || bot_email.nil?
        autobump_prefix = autobump_disabled ? <<~COMMENT : ""
          # TODO: Configure the bot before enabling this workflow:
          # 1. Create a GitHub personal access token with appropriate permissions
          # 2. Add it as a repository secret named BOT_TOKEN
          # 3. Rename this file to autobump.yml
          # 4. Add cask names to .github/autobump.txt
          #
        COMMENT

        autobump_yml = <<~ERB
          <%= autobump_prefix -%>
          name: Bump casks on schedule or request

          on:
            workflow_dispatch:
              inputs:
                casks:
                  description: Custom list of casks to livecheck and bump if outdated
                  required: false
            schedule:
              # Every 3 hours 23 minutes past the hour
              - cron: "23 */3 * * *"

          permissions:
            contents: read

          jobs:
            autobump:
              if: github.repository == '<%= tap.user %>/homebrew-<%= tap.repository %>'
              env:
                HOMEBREW_DEVELOPER: 1
              runs-on: macos-latest
              steps:
                - name: Set up Homebrew
                  id: set-up-homebrew
                  uses: Homebrew/actions/setup-homebrew@main
                  with:
                    core: true
                    cask: true

                - name: Configure Git user
                  uses: Homebrew/actions/git-user-config@main
                  with:
                    username: <%= bot_username || "${{ (github.event_name == 'workflow_dispatch' && github.actor) || 'BrewTestBot' }}" %>

                - name: Bump casks
                  id: autobump
                  env:
                    HOMEBREW_TEST_BOT_AUTOBUMP: 1
                    HOMEBREW_GITHUB_API_TOKEN: ${{ secrets.BOT_TOKEN }}
                    HOMEBREW_GIT_COMMITTER_NAME: <%= bot_username || 'TODO: set HOMEBREW_GIT_COMMITTER_NAME' %>
                    HOMEBREW_GIT_COMMITTER_EMAIL: <%= bot_email || 'TODO: set HOMEBREW_GIT_COMMITTER_EMAIL' %>
                    CASKS: ${{ inputs.casks }}
                  continue-on-error: true
                  run: |
                    BREW_BUMP=(brew bump --no-fork --open-pr --casks)
                    if [[ -n "${CASKS-}" ]]; then
                      xargs "${BREW_BUMP[@]}" <<<"${CASKS}"
                    else
                      "${BREW_BUMP[@]}" --auto --tap=<%= tap.user %>/<%= tap.repository %>
                    fi
        ERB

        autobump_key = autobump_disabled ? "autobump.yml.disabled" : "autobump.yml"

        {
          "ci.yml"       => ERB.new(ci_yml, trim_mode: "-").result(binding),
          "ci-retry.yml" => ci_retry_yml,
          autobump_key   => ERB.new(autobump_yml, trim_mode: "-").result(binding),
        }
      end

      sig {
        params(
          branch: String,
          tap:    Tap,
        ).returns(T::Hash[String, String])
      }
      def shared_workflow_files(branch, tap)
        actionlint_yml = <<~ERB
          name: Actionlint

          on:
            push:
              branches:
                - <%= branch %>
            pull_request:

          defaults:
            run:
              shell: bash -xeuo pipefail {0}

          concurrency:
            group: "actionlint-${{ github.ref }}"
            cancel-in-progress: ${{ github.event_name == 'pull_request' }}

          env:
            HOMEBREW_DEVELOPER: 1
            HOMEBREW_NO_AUTO_UPDATE: 1
            HOMEBREW_NO_ENV_HINTS: 1

          permissions: {}

          jobs:
            workflow_syntax:
              if: github.repository_owner == '<%= tap.user %>'
              runs-on: ubuntu-latest
              permissions:
                contents: read
              steps:
                - name: Set up Homebrew
                  id: setup-homebrew
                  uses: Homebrew/actions/setup-homebrew@main
                  with:
                    core: false
                    cask: false

                - uses: Homebrew/actions/cache-homebrew-prefix@main
                  with:
                    install: actionlint shellcheck zizmor

                - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
                  with:
                    persist-credentials: false

                - run: zizmor --format sarif . > results.sarif
                  env:
                    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

                - name: Upload SARIF file
                  uses: actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f # v6.0.0
                  if: always()
                  with:
                    name: results.sarif
                    path: results.sarif

                - name: Set up actionlint
                  run: echo "::add-matcher::$(brew --repository)/.github/actionlint-matcher.json"

                - run: actionlint

            upload_sarif:
              needs: workflow_syntax
              if: >
                always() &&
                !contains(fromJSON('["cancelled", "skipped"]'), needs.workflow_syntax.result) &&
                !github.event.repository.private
              runs-on: ubuntu-slim
              permissions:
                contents: read
                security-events: write
              steps:
                - name: Download SARIF file
                  uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
                  with:
                    name: results.sarif
                    path: results.sarif

                - name: Upload SARIF file
                  uses: github/codeql-action/upload-sarif@45cbd0c69e560cd9e7cd7f8c32362050c9b7ded2 # v4.32.2
                  with:
                    sarif_file: results.sarif
                    category: zizmor
        ERB

        cache_yml = <<~ERB
          name: Cache

          on:
            push:
              paths:
                - .github/workflows/cache.yml
            schedule:
              - cron: "0 */6 * * *" # every 6 hours

          concurrency:
            group: cache
            cancel-in-progress: true

          permissions:
            contents: read

          jobs:
            update:
              if: github.repository_owner == '<%= tap.user %>'
              strategy:
                matrix:
                  runner:
                    - macos-14
                    - macos-15
                    - macos-15-intel
                    - macos-26
                    - ubuntu-latest
              runs-on: ${{ matrix.runner }}
              steps:
                - name: Set up Homebrew
                  id: set-up-homebrew
                  uses: Homebrew/actions/setup-homebrew@main
                  with:
                    core: false
                    cask: false

                - name: Cache Homebrew Gems
                  id: cache
                  uses: actions/cache@cdf6c1fa76f9f475f3d7449005a359c84ca0f306 # v5.0.3
                  with:
                    path: ${{ steps.set-up-homebrew.outputs.gems-path }}
                    key: ${{ matrix.runner }}-rubygems-${{ steps.set-up-homebrew.outputs.gems-hash }}
                    restore-keys: ${{ matrix.runner }}-rubygems-

                - name: Install Homebrew Gems
                  id: gems
                  run: brew install-bundler-gems --groups=audit,style
        ERB

        {
          "actionlint.yml" => ERB.new(actionlint_yml, trim_mode: "-").result(binding),
          "cache.yml"      => ERB.new(cache_yml, trim_mode: "-").result(binding),
        }
      end

      sig {
        params(
          tap:                  Tap,
          titleized_user:       String,
          titleized_repository: String,
          generate_formula:     T::Boolean,
          generate_cask:        T::Boolean,
        ).returns(String)
      }
      def readme_content(tap, titleized_user, titleized_repository, generate_formula, generate_cask)
        sharding_note = <<~MARKDOWN

          > **Note:** For larger taps, Homebrew supports sharding formulae and casks into
          > subdirectories (e.g., `Formula/a/`, `Casks/f/`). See the
          > [Tap documentation](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
          > for details.
        MARKDOWN

        if generate_formula && generate_cask
          <<~MARKDOWN
            # #{titleized_user} #{titleized_repository}

            ## How do I install these formulae?

            `brew install #{tap}/<formula>`

            Or `brew tap #{tap}` and then `brew install <formula>`.

            Or, in a `brew bundle` `Brewfile`:

            ```ruby
            tap "#{tap}"
            brew "<formula>"
            ```

            ## How do I install these casks?

            `brew install --cask #{tap}/<cask>`

            Or `brew tap #{tap}` and then `brew install --cask <cask>`.

            Or, in a `brew bundle` `Brewfile`:

            ```ruby
            tap "#{tap}"
            cask "<cask>"
            ```

            ## Documentation

            `brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
            #{sharding_note}
          MARKDOWN
        elsif generate_cask
          <<~MARKDOWN
            # #{titleized_user} #{titleized_repository}

            ## How do I install these casks?

            `brew install --cask #{tap}/<cask>`

            Or `brew tap #{tap}` and then `brew install --cask <cask>`.

            Or, in a `brew bundle` `Brewfile`:

            ```ruby
            tap "#{tap}"
            cask "<cask>"
            ```

            ## Documentation

            `brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
            #{sharding_note}
          MARKDOWN
        else
          <<~MARKDOWN
            # #{titleized_user} #{titleized_repository}

            ## How do I install these formulae?

            `brew install #{tap}/<formula>`

            Or `brew tap #{tap}` and then `brew install <formula>`.

            Or, in a `brew bundle` `Brewfile`:

            ```ruby
            tap "#{tap}"
            brew "<formula>"
            ```

            ## Documentation

            `brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
            #{sharding_note}
          MARKDOWN
        end
      end

      sig { returns(String) }
      def autobump_txt_content
        <<~TXT
          # List formula or cask names to automatically bump, one per line.
          # These will be checked by `brew bump --auto` on the schedule defined
          # in .github/workflows/autobump.yml.
          # See: https://docs.brew.sh/Manpage#bump-options-formulacask-
        TXT
      end

      sig { params(tap: Tap, filename: T.any(String, Pathname), content: String).void }
      def write_path(tap, filename, content)
        path = tap.path/filename
        tap.path.mkpath
        odie "#{path} already exists" if path.exist?

        path.write content
      end
    end
  end
end
