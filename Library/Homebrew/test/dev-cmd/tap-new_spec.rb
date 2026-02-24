# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/tap-new"

RSpec.describe Homebrew::DevCmd::TapNew do
  it_behaves_like "parseable arguments"

  it "initializes a new tap with a README file and GitHub Actions CI", :integration_test do
    # To ensure that Utils::Git.setup_gpg! doesn't raise an error
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--verbose", "homebrew/foo" }
      .to be_a_success
      .and output(%r{homebrew/foo}).to_stdout
      .and not_to_output.to_stderr

    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-foo/README.md").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-foo/.github/workflows/tests.yml").to exist
  end

  it "creates a cask tap with --cask flag", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--cask", "homebrew/cask" }
      .to be_a_success
      .and output(%r{homebrew/cask}).to_stdout

    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-cask/Casks").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-cask/.github/autobump.txt").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-cask/Formula").not_to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-cask/.github/workflows/tests.yml").not_to exist
    readme = (HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-cask/README.md").read
    expect(readme).to include("brew install --cask")
    expect(readme).not_to include("brew install homebrew/cask/<formula>")
  end

  context "when invoking directly" do
    subject(:tap_new) { described_class.new(args) }

    let(:tap_name) { "homebrew/bar" }
    let(:args) { ["--no-git", tap_name] }

    before do
      allow(tap_new).to receive(:safe_system)
    end

    context "with --formula flag" do
      let(:args) { ["--no-git", "--formula", tap_name] }

      it "creates Formula directory and formula workflows" do
        tap_new.run

        tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar"
        expect(tap_path/"Formula").to be_a_directory
        expect(tap_path/".github/workflows/tests.yml").to exist
        expect(tap_path/".github/workflows/publish.yml").to exist
        expect(tap_path/".github/autobump.txt").to exist
      end
    end

    context "with --formula --cask flags" do
      let(:args) { ["--no-git", "--formula", "--cask", tap_name] }

      it "creates both Formula and Casks directories" do
        tap_new.run

        tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar"
        expect(tap_path/"Formula").to be_a_directory
        expect(tap_path/"Casks").to be_a_directory
        expect(tap_path/".github/workflows/tests.yml").to exist
        expect(tap_path/".github/autobump.txt").to exist

        readme = (tap_path/"README.md").read
        expect(readme).to include("brew install #{tap_name}/<formula>")
        expect(readme).to include("brew install --cask #{tap_name}/<cask>")
      end
    end

    context "with --cask --github-packages but without --formula" do
      let(:args) { ["--no-git", "--cask", "--github-packages", tap_name] }

      it "raises an error" do
        expect { tap_new.run }.to raise_error(SystemExit)
      end
    end

    context "with --formula --cask --github-packages" do
      let(:args) { ["--no-git", "--formula", "--cask", "--github-packages", tap_name] }

      it "creates both directories" do
        tap_new.run

        tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar"
        expect(tap_path/"Formula").to be_a_directory
        expect(tap_path/"Casks").to be_a_directory
      end
    end

    it "always creates .github/autobump.txt" do
      tap_new.run

      tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar"
      expect(tap_path/".github/autobump.txt").to exist
    end
  end
end
