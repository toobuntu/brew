# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/extract"

RSpec.describe Homebrew::DevCmd::Extract do
  it_behaves_like "parseable arguments"

  context "when extracting a formula" do
    let!(:target) do
      path = HOMEBREW_TAP_DIRECTORY/"homebrew/homebrew-foo"
      (path/"Formula").mkpath
      target = Tap.from_path(path)
      core_tap = CoreTap.instance
      core_tap.path.cd do
        system "git", "init"
        # Start with deprecated bottle syntax
        setup_test_formula "testball", bottle_block: <<~EOS

          bottle do
            cellar :any
          end
        EOS
        system "git", "add", "--all"
        system "git", "commit", "-m", "testball 0.1"
        # Replace with a valid formula for the next version
        formula_file = setup_test_formula "testball"
        contents = File.read(formula_file)
        contents.gsub!("testball-0.1", "testball-0.2")
        File.write(formula_file, contents)
        system "git", "add", "--all"
        system "git", "commit", "-m", "testball 0.2"
      end
      { name: target.name, path: }
    end

    it "retrieves the most recent version of formula", :integration_test do
      path = target[:path]/"Formula/t/testball@0.2.rb"
      expect { brew "extract", "testball", target[:name] }
        .to output(/^#{path}$/).to_stdout
        .and not_to_output.to_stderr
        .and be_a_success
      expect(path).to exist
      expect(Formulary.factory(path).version).to eq "0.2"
    end

    it "retrieves the specified version of formula", :integration_test do
      path = target[:path]/"Formula/t/testball@0.1.rb"
      expect { brew "extract", "testball", target[:name], "--version=0.1" }
        .to output(/^#{path}$/).to_stdout
        .and not_to_output.to_stderr
        .and be_a_success
      expect(path).to exist
      expect(Formulary.factory(path).version).to eq "0.1"
    end

    it "retrieves the compatible version of formula", :integration_test do
      path = target[:path]/"Formula/t/testball@0.rb"
      expect { brew "extract", "testball", target[:name], "--version=0" }
        .to output(/^#{path}$/).to_stdout
        .and not_to_output.to_stderr
        .and be_a_success
      expect(path).to exist
      expect(Formulary.factory(path).version).to eq "0.2"
    end

    it "extracts unversioned formula with --unversioned", :integration_test do
      path = target[:path]/"Formula/t/testball.rb"
      expect { brew "extract", "testball", target[:name], "--unversioned" }
        .to output(/^#{path}$/).to_stdout
        .and not_to_output.to_stderr
        .and be_a_success
      expect(path).to exist
      expect(Formulary.factory(path).version).to eq "0.2"
    end
  end

  context "when extracting a cask" do
    let!(:target) do
      path = HOMEBREW_TAP_DIRECTORY/"homebrew/homebrew-foo"
      (path/"Casks").mkpath
      target = Tap.from_path(path)
      core_cask_tap = CoreCaskTap.instance
      core_cask_tap.path.mkpath
      core_cask_tap.path.cd do
        system "git", "init"
        cask_dir = core_cask_tap.path/"Casks/t"
        cask_dir.mkpath
        cask_file = cask_dir/"testcask.rb"
        cask_file.write <<~RUBY
          cask "testcask" do
            version "1.0"
            sha256 "abc123"
            url "https://example.com/testcask-1.0.dmg"
            name "Test Cask"
            homepage "https://example.com"
            app "TestCask.app"
          end
        RUBY
        system "git", "add", "--all"
        system "git", "commit", "-m", "testcask 1.0"
        cask_file.write <<~RUBY
          cask "testcask" do
            version "2.0"
            sha256 "def456"
            url "https://example.com/testcask-2.0.dmg"
            name "Test Cask"
            homepage "https://example.com"
            app "TestCask.app"
          end
        RUBY
        system "git", "add", "--all"
        system "git", "commit", "-m", "testcask 2.0"
      end
      { name: target.name, path: }
    end

    it "retrieves the most recent version of cask", :integration_test do
      path = target[:path]/"Casks/t/testcask@2.0.rb"
      expect { brew "extract", "--cask", "testcask", target[:name] }
        .to output(/^#{path}$/).to_stdout
        .and not_to_output.to_stderr
        .and be_a_success
      expect(path).to exist
      expect(path.read).to include("cask \"testcask@2.0\" do")
    end
  end
end
