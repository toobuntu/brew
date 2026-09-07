# typed: true
# frozen_string_literal: true

require "formula_versions"

RSpec.describe FormulaVersions do
  it "loads historical formulae that use legacy bottle syntax" do
    current = formula("legacy-bottle") do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/legacy-bottle-2.0.tar.gz"
    end
    versions = described_class.new(current)
    digest = "a" * 64
    contents = <<~RUBY
      class LegacyBottle < Formula
        url "https://brew.sh/legacy-bottle-1.0.tar.gz"

        bottle do
          cellar :any_skip_relocation
          sha256 "#{digest}" => :big_sur
        end
      end
    RUBY
    allow(versions).to receive(:file_contents_at_revision).and_return(contents)

    result = versions.formula_at_revision("abc123") do |historical|
      tag = Utils::Bottles::Tag.from_symbol(:big_sur)
      tag_spec = historical.bottle_specification.tag_specification_for(tag)
      [historical.pkg_version.to_s, tag_spec&.checksum&.hexdigest, tag_spec&.cellar]
    end

    expect(result).to eq ["1.0", digest, :any_skip_relocation]
  end
end
