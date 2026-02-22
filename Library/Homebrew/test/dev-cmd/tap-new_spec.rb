# typed: strict
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

  it "creates a formula tap with explicit --formula flag", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "homebrew/bar" }
      .to be_a_success
      .and output(%r{homebrew/bar}).to_stdout

    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar/Formula").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar/.github/workflows/tests.yml").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar/.github/workflows/publish.yml").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar/.github/autobump.txt").to exist
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

  it "creates both Formula/ and Casks/ with --formula --cask flags", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "--cask", "homebrew/test-bot" }
      .to be_a_success
      .and output(%r{homebrew/test-bot}).to_stdout

    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-test-bot/Formula").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-test-bot/Casks").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-test-bot/.github/workflows/tests.yml").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-test-bot/.github/autobump.txt").to exist
    readme = (HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-test-bot/README.md").read
    expect(readme).to include("brew install homebrew/test-bot/<formula>")
    expect(readme).to include("brew install --cask homebrew/test-bot/<cask>")
  end

  it "fails when --github-packages and --cask are set without --formula", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--cask", "--github-packages", "homebrew/shallow" }
      .to be_a_failure
      .and output(/--github-packages.*--formula/).to_stderr
  end

  it "succeeds with --formula --cask --github-packages", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "--cask", "--github-packages", "homebrew/shallow" }
      .to be_a_success
      .and output(%r{homebrew/shallow}).to_stdout

    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-shallow/Formula").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-shallow/Casks").to exist
  end

  it "creates .github/autobump.txt for the default formula tap", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "homebrew/foo" }
      .to be_a_success

    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-foo/.github/autobump.txt").to exist
  end
end
