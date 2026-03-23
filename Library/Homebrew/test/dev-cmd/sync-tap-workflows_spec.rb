# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/sync_tap_workflows"

RSpec.describe Homebrew::DevCmd::SyncTapWorkflows do
  subject(:command) { described_class.new(["--cask", "testuser/testcask"]) }

  it_behaves_like "parseable arguments"

  describe "#adapt_condition" do
    let(:tap) { Tap.fetch("myorg", "mycask") }

    it "replaces repository_owner check" do
      result = command.send(:adapt_condition, "github.repository_owner == 'Homebrew'", tap)
      expect(result).to eq("github.repository_owner == 'myorg'")
    end

    it "replaces homebrew-cask repository check" do
      result = command.send(:adapt_condition, "github.repository == 'Homebrew/homebrew-cask'", tap)
      expect(result).to eq("github.repository == 'myorg/homebrew-mycask'")
    end

    it "replaces homebrew-core repository check" do
      result = command.send(:adapt_condition, "github.repository == 'Homebrew/homebrew-core'", tap)
      expect(result).to eq("github.repository == 'myorg/homebrew-mycask'")
    end

    it "removes merge_group suffix condition" do
      result = command.send(:adapt_condition,
                            "github.event_name == 'push' || github.event_name == 'merge_group'", tap)
      expect(result).to eq("github.event_name == 'push'")
    end

    it "removes merge_group prefix condition" do
      result = command.send(:adapt_condition,
                            "github.event_name == 'merge_group' || github.event_name == 'push'", tap)
      expect(result).to eq("github.event_name == 'push'")
    end
  end

  describe "#adapt_run_script" do
    let(:tap) { Tap.fetch("myorg", "mycask") }

    it "replaces join(matrix.audit_args) with --online --strict" do
      result = command.send(:adapt_run_script, "brew audit ${{ join(matrix.audit_args, ' ') }}", tap)
      expect(result).to eq("brew audit --online --strict")
    end

    it "replaces --tap=Homebrew/cask" do
      result = command.send(:adapt_run_script, "brew install --tap=Homebrew/cask foo", tap)
      expect(result).to eq("brew install --tap=myorg/mycask foo")
    end

    it "replaces --tap=Homebrew/core" do
      result = command.send(:adapt_run_script, "brew install --tap=Homebrew/core foo", tap)
      expect(result).to eq("brew install --tap=myorg/mycask foo")
    end
  end

  describe "#apply_general_mutations!" do
    let(:tap) { Tap.fetch("myorg", "mycask") }

    it "updates push branches" do
      yaml = { "on" => { "push" => { "branches" => ["master"] } } }
      command.send(:apply_general_mutations!, yaml, tap, "main")
      expect(yaml["on"]["push"]["branches"]).to eq(["main"])
    end

    it "removes merge_group trigger" do
      yaml = { "on" => { "push" => {}, "merge_group" => {} } }
      command.send(:apply_general_mutations!, yaml, tap, "main")
      expect(yaml["on"]).not_to have_key("merge_group")
    end

    it "updates job if: conditions" do
      yaml = {
        "on"   => {},
        "jobs" => {
          "test" => {
            "if"    => "github.repository_owner == 'Homebrew'",
            "steps" => [],
          },
        },
      }
      command.send(:apply_general_mutations!, yaml, tap, "main")
      expect(yaml["jobs"]["test"]["if"]).to eq("github.repository_owner == 'myorg'")
    end
  end

  describe "#apply_autobump_mutations!" do
    it "removes Set up commit signing step" do
      yaml = {
        "jobs" => {
          "autobump" => {
            "steps" => [
              { "name" => "Set up commit signing", "uses" => "some/action" },
              { "name" => "Run autobump", "run" => "brew bump" },
            ],
          },
        },
      }
      command.send(:apply_autobump_mutations!, yaml, nil, nil)
      step_names = yaml["jobs"]["autobump"]["steps"].map { |s| s["name"] }
      expect(step_names).not_to include("Set up commit signing")
      expect(step_names).to include("Run autobump")
    end

    it "replaces HOMEBREW_CASK_REPO_WORKFLOW_TOKEN with BOT_TOKEN" do
      yaml = {
        "jobs" => {
          "autobump" => {
            "steps" => [
              {
                "name" => "Run autobump",
                "env"  => {
                  "HOMEBREW_GITHUB_API_TOKEN" => "${{ secrets.HOMEBREW_CASK_REPO_WORKFLOW_TOKEN }}",
                },
              },
            ],
          },
        },
      }
      command.send(:apply_autobump_mutations!, yaml, nil, nil)
      env = yaml["jobs"]["autobump"]["steps"].first["env"]
      expect(env["HOMEBREW_GITHUB_API_TOKEN"]).to eq("${{ secrets.BOT_TOKEN }}")
    end

    it "replaces bot username when provided" do
      yaml = {
        "jobs" => {
          "autobump" => {
            "steps" => [
              {
                "name" => "Run autobump",
                "env"  => { "HOMEBREW_GIT_COMMITTER_NAME" => "BrewTestBot" },
              },
            ],
          },
        },
      }
      command.send(:apply_autobump_mutations!, yaml, "MyBot", nil)
      env = yaml["jobs"]["autobump"]["steps"].first["env"]
      expect(env["HOMEBREW_GIT_COMMITTER_NAME"]).to eq("MyBot")
    end

    it "replaces bot email when provided" do
      yaml = {
        "jobs" => {
          "autobump" => {
            "steps" => [
              {
                "name" => "Run autobump",
                "env"  => {
                  "HOMEBREW_GIT_COMMITTER_EMAIL" => "1589480+BrewTestBot@users.noreply.github.com",
                },
              },
            ],
          },
        },
      }
      command.send(:apply_autobump_mutations!, yaml, nil, "42+mybot@users.noreply.github.com")
      env = yaml["jobs"]["autobump"]["steps"].first["env"]
      expect(env["HOMEBREW_GIT_COMMITTER_EMAIL"]).to eq("42+mybot@users.noreply.github.com")
    end
  end
end
