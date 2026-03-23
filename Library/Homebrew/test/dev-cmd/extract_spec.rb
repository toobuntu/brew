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
      path = target[:path]/"Formula/testball@0.2.rb"
      expect { brew "extract", "testball", target[:name] }
        .to output(/^#{path}$/).to_stdout
        .and not_to_output.to_stderr
        .and be_a_success
      expect(path).to exist
      expect(Formulary.factory(path).version).to eq "0.2"
    end

    it "retrieves the specified version of formula", :integration_test do
      path = target[:path]/"Formula/testball@0.1.rb"
      expect { brew "extract", "testball", target[:name], "--version=0.1" }
        .to output(/^#{path}$/).to_stdout
        .and not_to_output.to_stderr
        .and be_a_success
      expect(path).to exist
      expect(Formulary.factory(path).version).to eq "0.1"
    end

    it "retrieves the compatible version of formula", :integration_test do
      path = target[:path]/"Formula/testball@0.rb"
      expect { brew "extract", "testball", target[:name], "--version=0" }
        .to output(/^#{path}$/).to_stdout
        .and not_to_output.to_stderr
        .and be_a_success
      expect(path).to exist
      expect(Formulary.factory(path).version).to eq "0.2"
    end
  end

  describe "#add_quarantine_postflight" do
    subject(:command) { described_class.new(["somecask", "homebrew/foo"]) }

    let(:cask_content_with_app) do
      <<~RUBY
        cask "mycask" do
          version "1.0"
          sha256 "abc123"

          url "https://example.com/mycask-1.0.dmg"
          homepage "https://example.com"

          app "MyCask.app"
        end
      RUBY
    end

    let(:cask_content_with_multiple_apps) do
      <<~RUBY
        cask "mycask" do
          version "1.0"
          sha256 "abc123"

          url "https://example.com/mycask-1.0.dmg"
          homepage "https://example.com"

          app "MyCask.app"
          app "MyCaskHelper.app"
        end
      RUBY
    end

    let(:cask_content_no_app) do
      <<~RUBY
        cask "mycask" do
          version "1.0"
          sha256 "abc123"

          url "https://example.com/mycask-1.0.pkg"
          homepage "https://example.com"

          pkg "MyCask.pkg"
        end
      RUBY
    end

    let(:cask_content_with_existing_quarantine) do
      <<~RUBY
        cask "mycask" do
          version "1.0"
          sha256 "abc123"

          url "https://example.com/mycask-1.0.dmg"
          homepage "https://example.com"

          app "MyCask.app"

          postflight do
            system_command "/usr/bin/xattr",
                           args: ["-dr", "com.apple.quarantine", "#{appdir}/MyCask.app"],
                           sudo: false
          end
        end
      RUBY
    end

    it "adds a postflight block for a single app stanza" do
      result = command.send(:add_quarantine_postflight, cask_content_with_app)
      expect(result).to include("postflight do")
      expect(result).to include("com.apple.quarantine")
      expect(result).to include("MyCask.app")
      expect(result).to include("system_command \"/usr/bin/xattr\"")
    end

    it "adds xattr removal for each app when multiple app stanzas are present" do
      result = command.send(:add_quarantine_postflight, cask_content_with_multiple_apps)
      expect(result).to include("MyCask.app")
      expect(result).to include("MyCaskHelper.app")
      expect(result.scan("com.apple.quarantine").count).to eq(2)
    end

    it "returns content unchanged and warns when no app stanza is found" do
      expect(command).to receive(:opoo).with(/No app stanza found/)
      result = command.send(:add_quarantine_postflight, cask_content_no_app)
      expect(result).to eq(cask_content_no_app)
    end

    it "returns content unchanged and warns when postflight already handles quarantine" do
      expect(command).to receive(:opoo).with(/already handles quarantine/)
      result = command.send(:add_quarantine_postflight, cask_content_with_existing_quarantine)
      expect(result).to eq(cask_content_with_existing_quarantine)
    end
  end
end
