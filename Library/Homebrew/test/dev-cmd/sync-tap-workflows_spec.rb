# typed: strict
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/sync-tap-workflows"

RSpec.describe Homebrew::DevCmd::SyncTapWorkflows do
  it_behaves_like "parseable arguments"

  it "raises an error when neither --cask nor --formula is specified", :integration_test do
    expect { brew "sync-tap-workflows", "homebrew/foo" }
      .to be_a_failure
      .and output(/Specify either/).to_stderr
  end

  describe "workflow adaptation" do
    subject(:command) { described_class.new(["--cask", "testuser/myrepo"]) }

    let(:tap) { instance_double(Tap, user: "testuser", repository: "myrepo") }

    describe "#adapt_cask_ci" do
      let(:ci_yml) do
        <<~YAML
          name: CI

          on:
            push:
              branches:
                - main
                - master
            pull_request:
            merge_group:
            workflow_dispatch:

          jobs:
            generate-matrix:
              steps:
                - name: Run brew config
                  run: brew config

                - name: Generate CI matrix
                  id: generate-matrix
                  run: |
                    if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]
                    then
                      brew generate-cask-ci-matrix --casks $INPUT_CASKS
                    elif [[ "${GITHUB_EVENT_NAME}" == "push" || "${GITHUB_EVENT_NAME}" == "merge_group" ]]
                    then
                      brew generate-cask-ci-matrix --syntax-only
                    else
                      brew generate-cask-ci-matrix --url "$PULL_REQUEST_URL"
                    fi

            test:
              steps:
                - name: Run brew config
                  run: brew config

                - name: Run brew audit
                  run: brew audit --cask ${{ join(matrix.audit_args, ' ') }} '${{ matrix.cask.token }}'
        YAML
      end

      it "replaces push branches with the specified branch" do
        result = command.send(:adapt_cask_ci, ci_yml, "develop")
        expect(result).to include("      - develop\n")
        expect(result).not_to include("      - main\n")
        expect(result).not_to include("      - master\n")
      end

      it "removes the merge_group trigger" do
        result = command.send(:adapt_cask_ci, ci_yml, "main")
        expect(result).not_to include("  merge_group:\n")
      end

      it "removes brew config steps" do
        result = command.send(:adapt_cask_ci, ci_yml, "main")
        expect(result).not_to include("Run brew config")
      end

      it "removes merge_group branch from generate-matrix script" do
        result = command.send(:adapt_cask_ci, ci_yml, "main")
        expect(result).not_to include('"merge_group"')
        expect(result).to include('"${GITHUB_EVENT_NAME}" == "push"')
      end

      it "replaces matrix.audit_args with hardcoded flags" do
        result = command.send(:adapt_cask_ci, ci_yml, "main")
        expect(result).to include("--online --strict")
        expect(result).not_to include("join(matrix.audit_args")
      end
    end

    describe "#adapt_actionlint" do
      let(:actionlint_yml) do
        <<~YAML
          name: Actionlint

          on:
            push:
              branches:
                - main
                - master
            pull_request:

          jobs:
            workflow_syntax:
              if: github.repository_owner == 'Homebrew'

            upload_sarif:
              if: >
                always() &&
                !github.event.repository.private &&
                github.event_name != 'merge_group'
        YAML
      end

      it "replaces push branches" do
        result = command.send(:adapt_actionlint, actionlint_yml, "trunk", "myorg")
        expect(result).to include("      - trunk\n")
        expect(result).not_to include("      - main\n")
      end

      it "replaces the org guard with the tap user" do
        result = command.send(:adapt_actionlint, actionlint_yml, "main", "myorg")
        expect(result).to include("github.repository_owner == 'myorg'")
        expect(result).not_to include("github.repository_owner == 'Homebrew'")
      end

      it "removes merge_group reference from upload_sarif condition" do
        result = command.send(:adapt_actionlint, actionlint_yml, "main", "myorg")
        expect(result).not_to include("merge_group")
      end
    end

    describe "#adapt_cask_autobump" do
      let(:autobump_yml) do
        <<~YAML
          name: Bump casks

          jobs:
            autobump:
              if: github.repository == 'Homebrew/homebrew-cask'
              steps:
                - name: Configure Git user
                  uses: Homebrew/actions/git-user-config@main
                  with:
                    username: ${{ (github.event_name == 'workflow_dispatch' && github.actor) || 'BrewTestBot' }}

                - name: Set up commit signing
                  uses: Homebrew/actions/setup-commit-signing@main
                  with:
                    signing_key: ${{ secrets.BREWTESTBOT_SSH_SIGNING_KEY }}

                - name: Bump casks
                  env:
                    HOMEBREW_GITHUB_API_TOKEN: ${{ secrets.HOMEBREW_CASK_REPO_WORKFLOW_TOKEN }}
                    HOMEBREW_GIT_COMMITTER_NAME: BrewTestBot
                    HOMEBREW_GIT_COMMITTER_EMAIL: 1589480+BrewTestBot@users.noreply.github.com
                  run: |
                    "${BREW_BUMP[@]}" --auto --tap=Homebrew/cask
        YAML
      end

      it "replaces the repo guard with the tap's full repository" do
        result = command.send(:adapt_cask_autobump, autobump_yml, tap, "MyBot", "bot@example.com")
        expect(result).to include("github.repository == 'testuser/homebrew-myrepo'")
        expect(result).not_to include("Homebrew/homebrew-cask")
      end

      it "removes the commit signing step" do
        result = command.send(:adapt_cask_autobump, autobump_yml, tap, "MyBot", "bot@example.com")
        expect(result).not_to include("Set up commit signing")
        expect(result).not_to include("BREWTESTBOT_SSH_SIGNING_KEY")
      end

      it "replaces the Homebrew API token secret" do
        result = command.send(:adapt_cask_autobump, autobump_yml, tap, "MyBot", "bot@example.com")
        expect(result).to include("secrets.BOT_TOKEN")
        expect(result).not_to include("HOMEBREW_CASK_REPO_WORKFLOW_TOKEN")
      end

      it "replaces the tap reference in the autobump command" do
        result = command.send(:adapt_cask_autobump, autobump_yml, tap, "MyBot", "bot@example.com")
        expect(result).to include("--auto --tap=testuser/myrepo")
        expect(result).not_to include("--auto --tap=Homebrew/cask")
      end

      context "when bot credentials are provided" do
        it "interpolates bot_username into Configure Git user" do
          result = command.send(:adapt_cask_autobump, autobump_yml, tap, "MyBot", "bot@example.com")
          expect(result).to include("username: MyBot")
        end

        it "interpolates bot_username into HOMEBREW_GIT_COMMITTER_NAME" do
          result = command.send(:adapt_cask_autobump, autobump_yml, tap, "MyBot", "bot@example.com")
          expect(result).to include("HOMEBREW_GIT_COMMITTER_NAME: MyBot")
        end

        it "interpolates bot_email into HOMEBREW_GIT_COMMITTER_EMAIL" do
          result = command.send(:adapt_cask_autobump, autobump_yml, tap, "MyBot", "bot@example.com")
          expect(result).to include("HOMEBREW_GIT_COMMITTER_EMAIL: bot@example.com")
        end
      end

      context "when bot credentials are not provided" do
        it "adds TODO placeholder for HOMEBREW_GIT_COMMITTER_NAME" do
          result = command.send(:adapt_cask_autobump, autobump_yml, tap, nil, nil)
          expect(result).to include("HOMEBREW_GIT_COMMITTER_NAME: # TODO: set bot username")
        end

        it "adds TODO placeholder for HOMEBREW_GIT_COMMITTER_EMAIL" do
          result = command.send(:adapt_cask_autobump, autobump_yml, tap, nil, nil)
          expect(result).to include("HOMEBREW_GIT_COMMITTER_EMAIL: # TODO: set bot email")
        end
      end
    end

    describe "#adapt_cache" do
      let(:cache_yml) do
        <<~YAML
          jobs:
            update:
              if: github.repository_owner == 'Homebrew'
        YAML
      end

      it "replaces the org guard with the tap user" do
        result = command.send(:adapt_cache, cache_yml, "myorg")
        expect(result).to include("github.repository_owner == 'myorg'")
        expect(result).not_to include("github.repository_owner == 'Homebrew'")
      end
    end

    describe "#adapt_cask_workflow" do
      it "returns autobump.yml.disabled when bot credentials are missing" do
        _adapted, filename = command.send(
          :adapt_cask_workflow, "autobump.yml", "content: {}", tap, "main", nil, nil
        )
        expect(filename).to eq("autobump.yml.disabled")
      end

      it "returns autobump.yml when bot credentials are provided" do
        _adapted, filename = command.send(
          :adapt_cask_workflow, "autobump.yml", "content: {}", tap, "main", "MyBot", "bot@example.com"
        )
        expect(filename).to eq("autobump.yml")
      end

      it "copies ci-retry.yml verbatim" do
        content = "name: CI Retry\njobs: {}"
        adapted, filename = command.send(:adapt_cask_workflow, "ci-retry.yml", content, tap, "main", nil, nil)
        expect(adapted).to eq(content)
        expect(filename).to eq("ci-retry.yml")
      end
    end

    describe "#adapt_formula_workflow" do
      it "returns autobump.yml.disabled when bot credentials are missing" do
        _adapted, filename = command.send(
          :adapt_formula_workflow, "autobump.yml", "content: {}", tap, "main", nil, nil
        )
        expect(filename).to eq("autobump.yml.disabled")
      end

      it "returns autobump.yml when bot credentials are provided" do
        _adapted, filename = command.send(
          :adapt_formula_workflow, "autobump.yml", "content: {}", tap, "main", "MyBot", "bot@example.com"
        )
        expect(filename).to eq("autobump.yml")
      end
    end

    describe "#adapt_formula_autobump" do
      let(:formula_autobump_yml) do
        <<~YAML
          name: Bump formulae

          on:
            push:
              branches:
                - main
                - master
              paths:
                - .github/workflows/autobump.yml

          jobs:
            autobump:
              if: github.repository_owner == 'Homebrew'
              runs-on: ubuntu-latest
              container:
                image: ghcr.io/homebrew/ubuntu22.04:main
              env:
                GNUPGHOME: /tmp/gnupghome
              steps:
                - name: Configure Git user
                  uses: Homebrew/actions/git-user-config@main
                  with:
                    username: ${{ (github.event_name == 'workflow_dispatch' && github.actor) || 'BrewTestBot' }}

                - name: Set up commit signing
                  uses: Homebrew/actions/setup-commit-signing@main
                  with:
                    signing_key: ${{ secrets.BREWTESTBOT_SSH_SIGNING_KEY }}

                - name: Bump formulae
                  env:
                    HOMEBREW_GITHUB_API_TOKEN: ${{ secrets.HOMEBREW_CORE_REPO_WORKFLOW_TOKEN }}
                    HOMEBREW_GIT_COMMITTER_NAME: BrewTestBot
                    HOMEBREW_GIT_COMMITTER_EMAIL: 1589480+BrewTestBot@users.noreply.github.com
                  run: |
                    "${BREW_BUMP[@]}" --auto --tap=Homebrew/core
        YAML
      end

      it "replaces push branches" do
        result = command.send(:adapt_formula_autobump, formula_autobump_yml, tap, "develop", "MyBot",
                              "bot@example.com")
        expect(result).to include("      - develop\n")
        expect(result).not_to include("      - main\n")
      end

      it "replaces the org guard with the tap user" do
        result = command.send(:adapt_formula_autobump, formula_autobump_yml, tap, "main", "MyBot", "bot@example.com")
        expect(result).to include("github.repository_owner == 'testuser'")
        expect(result).not_to include("github.repository_owner == 'Homebrew'")
      end

      it "removes the container block" do
        result = command.send(:adapt_formula_autobump, formula_autobump_yml, tap, "main", "MyBot", "bot@example.com")
        expect(result).not_to include("ghcr.io/homebrew/ubuntu22.04")
        expect(result).not_to include("container:")
      end

      it "removes GNUPGHOME env" do
        result = command.send(:adapt_formula_autobump, formula_autobump_yml, tap, "main", "MyBot", "bot@example.com")
        expect(result).not_to include("GNUPGHOME")
      end

      it "removes the commit signing step" do
        result = command.send(:adapt_formula_autobump, formula_autobump_yml, tap, "main", "MyBot", "bot@example.com")
        expect(result).not_to include("Set up commit signing")
      end

      it "replaces the tap reference in the autobump command" do
        result = command.send(:adapt_formula_autobump, formula_autobump_yml, tap, "main", "MyBot", "bot@example.com")
        expect(result).to include("--auto --tap=testuser/myrepo")
        expect(result).not_to include("--auto --tap=Homebrew/core")
      end

      it "replaces the Homebrew API token secret" do
        result = command.send(:adapt_formula_autobump, formula_autobump_yml, tap, "main", "MyBot", "bot@example.com")
        expect(result).to include("secrets.BOT_TOKEN")
        expect(result).not_to include("HOMEBREW_CORE_REPO_WORKFLOW_TOKEN")
      end
    end

    describe "#write_workflow with --dry-run" do
      subject(:dry_run_command) { described_class.new(["--cask", "--dry-run", "testuser/myrepo"]) }

      it "prints the file content and path without writing" do
        allow(tap).to receive(:path).and_return(Pathname(TEST_TMPDIR))

        content = "name: Test\njobs: {}\n"
        expect { dry_run_command.send(:write_workflow, tap, "test.yml", content) }
          .to output(a_string_including("Would write", content)).to_stdout

        expect(Pathname(TEST_TMPDIR)/".github"/"workflows"/"test.yml").not_to exist
      end
    end
  end
end
