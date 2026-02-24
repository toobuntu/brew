# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "erb"
require "fileutils"
require "tap"
require "utils/uid"

module Homebrew
  module DevCmd
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
        switch "--github-packages",
               description: "Upload bottles to GitHub Packages."
        flag   "--bot-username=",
               description: "GitHub username for the automated bump bot (used in autobump.yml)."
        flag   "--bot-email=",
               description: "Commit email for the automated bump bot, e.g. " \
                            "\"12345+bot@users.noreply.github.com\" (used in autobump.yml)."

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

        generate_formula = args.formula? || !args.cask?
        generate_cask = args.cask?

        bot_username = args.bot_username
        bot_email = args.bot_email

        titleized_user = tap.user.dup
        titleized_repository = tap.repository.dup
        titleized_user[0] = T.must(titleized_user[0]).upcase
        titleized_repository[0] = T.must(titleized_repository[0]).upcase
        # Duplicate assignment to silence `assigned but unused variable` warning
        root_url = root_url = GitHubPackages.root_url(tap.user, "homebrew-#{tap.repository}") if args.github_packages?

        (tap.path/"Formula").mkpath if generate_formula
        (tap.path/"Casks").mkpath if generate_cask

        sharding_note = <<~MARKDOWN

          > **Note:** For larger taps, Homebrew supports sharding formulae and casks into
          > subdirectories (e.g., `Formula/a/`, `Casks/f/`). See the
          > [Tap documentation](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
          > for details.
        MARKDOWN

        readme = if generate_formula && generate_cask
          <<~MARKDOWN
            # #{titleized_user} #{titleized_repository}

            ## How do I install these formulae and casks?

            For formulae: `brew install #{tap}/<formula>`

            For casks: `brew install --cask #{tap}/<cask>`

            Or `brew tap #{tap}` and then `brew install <formula>` / `brew install --cask <cask>`.

            Or, in a `brew bundle` `Brewfile`:

            ```ruby
            tap "#{tap}"
            brew "<formula>"
            cask "<cask>"
            ```

            ## Documentation

            `brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
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
          MARKDOWN
        end
        write_path(tap, "README.md", readme + sharding_note)

        if generate_formula
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
            <% if args.github_packages? -%>
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
            <% if args.github_packages? -%>
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
            <% if args.github_packages? -%>
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
            <% if args.github_packages? -%>
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
            <% if args.github_packages? -%>
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

          (tap.path/".github/workflows").mkpath
          write_path(tap, ".github/workflows/tests.yml", ERB.new(tests_yml, trim_mode: "-").result(binding))
          write_path(tap, ".github/workflows/publish.yml", ERB.new(publish_yml, trim_mode: "-").result(binding))
        end

        autobump_txt = <<~TEXT
          # List formula or cask names to automatically bump, one per line.
          # These will be checked by `brew bump --auto` on the schedule defined
          # in .github/workflows/autobump.yml.
          # See: https://docs.brew.sh/Manpage#bump-options-formulacask-
        TEXT
        (tap.path/".github").mkpath
        write_path(tap, ".github/autobump.txt", autobump_txt)

        if generate_cask || args.formula?
          sync_args = []
          sync_args << "--cask" if generate_cask
          sync_args << "--formula" if generate_formula
          sync_args << "--branch=#{branch}"
          sync_args << "--bot-username=#{bot_username}" if bot_username
          sync_args << "--bot-email=#{bot_email}" if bot_email
          sync_args << tap.name

          begin
            safe_system HOMEBREW_BREW_FILE, "sync-tap-workflows", *sync_args
          rescue ErrorDuringExecution
            opoo "Could not generate CI workflows."
            opoo "Run `brew sync-tap-workflows #{sync_args.join(" ")}` later to generate them."
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
        success_msg = if generate_formula && generate_cask
          <<~EOS
            #{tap.path}

            For formulae: label your PR as `#{label}` to trigger bottle publishing.
            For casks: merge directly once CI passes.
          EOS
        elsif generate_cask
          <<~EOS
            #{tap.path}

            When a pull request making changes to a cask becomes green
            (all checks passed), you can merge it directly.
          EOS
        else
          <<~EOS
            #{tap.path}

            When a pull request making changes to a formula (or formulae) becomes green
            (all checks passed), then you can publish the built bottles.
            To do so, label your PR as `#{label}` and the workflow will be triggered.
          EOS
        end
        if (generate_cask || args.formula?) && (bot_username.nil? || bot_email.nil?)
          success_msg += <<~EOS
            To enable automatic version bumping:
            1. Create a GitHub personal access token with appropriate permissions
            2. Add it as a repository secret named BOT_TOKEN
            3. Run `brew sync-tap-workflows --bot-username=<user> --bot-email=<email> #{tap.name}`
               to regenerate autobump.yml (currently disabled)
            4. Add package names to .github/autobump.txt
          EOS
        end
        puts success_msg
      end

      private

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
