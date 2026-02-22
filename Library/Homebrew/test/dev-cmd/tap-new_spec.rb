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

    tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-foo"
    expect(tap_path/"README.md").to exist
    expect(tap_path/".github/workflows/tests.yml").to exist
    expect(tap_path/".github/workflows/publish.yml").to exist
    expect(tap_path/"Formula").to be_a_directory
    # Default does not create the extra workflows
    expect(tap_path/".github/workflows/actionlint.yml").not_to exist
    expect(tap_path/".github/workflows/autobump.yml.disabled").not_to exist
  end

  it "creates formula scaffolding with extra workflows when --formula is explicit", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "homebrew/bar" }
      .to be_a_success

    tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bar"
    expect(tap_path/"Formula").to be_a_directory
    expect(tap_path/".github/workflows/tests.yml").to exist
    expect(tap_path/".github/workflows/publish.yml").to exist
    expect(tap_path/".github/workflows/actionlint.yml").to exist
    expect(tap_path/".github/workflows/cache.yml").to exist
    expect(tap_path/".github/workflows/autobump.yml.disabled").to exist
    expect((tap_path/".github/workflows/autobump.yml.disabled").read).to include("BrewTestBot")
    expect(tap_path/".github/autobump.txt").to exist
  end

  it "creates cask scaffolding when --cask is passed", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--cask", "homebrew/baz" }
      .to be_a_success

    tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-baz"
    expect(tap_path/"Casks").to be_a_directory
    expect(tap_path/"Formula").not_to exist
    expect(tap_path/".github/workflows/ci.yml").to exist
    expect(tap_path/".github/workflows/ci-retry.yml").to exist
    expect(tap_path/".github/workflows/actionlint.yml").to exist
    expect(tap_path/".github/workflows/cache.yml").to exist
    expect(tap_path/".github/workflows/autobump.yml.disabled").to exist
    expect(tap_path/".github/autobump.txt").to exist
    expect(tap_path/".github/workflows/tests.yml").not_to exist
    expect(tap_path/".github/workflows/publish.yml").not_to exist
  end

  it "creates mixed scaffolding when --formula --cask are both passed", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "--cask", "homebrew/mixed" }
      .to be_a_success

    tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-mixed"
    expect(tap_path/"Formula").to be_a_directory
    expect(tap_path/"Casks").to be_a_directory
    expect(tap_path/".github/workflows/tests.yml").to exist
    expect(tap_path/".github/workflows/publish.yml").to exist
    expect(tap_path/".github/workflows/ci.yml").to exist
    expect(tap_path/".github/workflows/ci-retry.yml").to exist
    expect(tap_path/".github/workflows/actionlint.yml").to exist
    expect(tap_path/".github/workflows/cache.yml").to exist
    expect(tap_path/".github/workflows/autobump-formulae.yml.disabled").to exist
    expect(tap_path/".github/workflows/autobump-casks.yml.disabled").to exist
    expect(tap_path/".github/autobump.txt").to exist
  end

  it "errors when --github-packages and --cask are passed without --formula", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--cask", "--github-packages", "homebrew/pkgcask" }
      .to be_a_failure
      .and output(/`--github-packages` requires `--formula`/).to_stderr
  end

  it "succeeds when --github-packages --formula --cask are all passed", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "--cask", "--github-packages", "homebrew/pkgboth" }
      .to be_a_success

    tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-pkgboth"
    expect(tap_path/".github/workflows/tests.yml").to exist
    expect(tap_path/".github/workflows/ci.yml").to exist
  end

  it "generates autobump.yml (not .disabled) when bot credentials are provided", :integration_test do
    setup_test_formula "gnupg"

    expect do
 brew "tap-new", "--no-git", "--formula", "--bot-username=mybot", "--bot-email=42+mybot@users.noreply.github.com",
      "homebrew/bottest"
    end
      .to be_a_success

    tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-bottest"
    expect(tap_path/".github/workflows/autobump.yml").to exist
    expect(tap_path/".github/workflows/autobump.yml.disabled").not_to exist
    autobump_content = (tap_path/".github/workflows/autobump.yml").read
    expect(autobump_content).to include("mybot")
    expect(autobump_content).to include("42+mybot@users.noreply.github.com")
    expect(autobump_content).not_to include("BrewTestBot")
  end

  it "interpolates --branch into workflow push triggers", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "--branch=develop", "homebrew/branched" }
      .to be_a_success

    tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-branched"
    tests_content = (tap_path/".github/workflows/tests.yml").read
    expect(tests_content).to include("- develop")
  end

  it "uses tap.user instead of 'Homebrew' in cask workflow org guards", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--cask", "myrg/myapp" }
      .to be_a_success

    tap_path = HOMEBREW_LIBRARY/"Taps/myrg/homebrew-myapp"
    actionlint_content = (tap_path/".github/workflows/actionlint.yml").read
    expect(actionlint_content).to include("myrg")
    expect(actionlint_content).not_to include("== 'Homebrew'")
  end

  it "silently ignores --pull-label for cask-only taps", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--cask", "--pull-label=my-label", "homebrew/labelcask" }
      .to be_a_success

    tap_path = HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-labelcask"
    expect(tap_path/".github/workflows/publish.yml").not_to exist
  end

  it "generates README with brew install for formula and brew install --cask for cask", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "homebrew/freadme" }
      .to be_a_success
    expect { brew "tap-new", "--no-git", "--cask", "homebrew/creadme" }
      .to be_a_success
    expect { brew "tap-new", "--no-git", "--formula", "--cask", "homebrew/mreadme" }
      .to be_a_success

    formula_readme = (HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-freadme/README.md").read
    cask_readme = (HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-creadme/README.md").read
    mixed_readme = (HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-mreadme/README.md").read

    expect(formula_readme).to include("brew install homebrew/freadme/<formula>")
    expect(formula_readme).not_to include("--cask")
    expect(cask_readme).to include("brew install --cask homebrew/creadme/<cask>")
    expect(cask_readme).not_to include('brew "<formula>"')
    expect(mixed_readme).to include("brew install homebrew/mreadme/<formula>")
    expect(mixed_readme).to include("brew install --cask homebrew/mreadme/<cask>")
  end

  it "creates .github/autobump.txt when --formula or --cask is passed", :integration_test do
    setup_test_formula "gnupg"

    expect { brew "tap-new", "--no-git", "--formula", "homebrew/autof" }
      .to be_a_success
    expect { brew "tap-new", "--no-git", "--cask", "homebrew/autoc" }
      .to be_a_success

    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-autof/.github/autobump.txt").to exist
    expect(HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-autoc/.github/autobump.txt").to exist
    autobump_txt = (HOMEBREW_LIBRARY/"Taps/homebrew/homebrew-autof/.github/autobump.txt").read
    expect(autobump_txt).to include("brew bump --auto")
  end
end
