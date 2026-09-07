# typed: strict
# frozen_string_literal: true

require "utils/output"

class BottleSpecification
  include Utils::Output::Mixin

  LEGACY_SYNTAX_KEY = :homebrew_legacy_bottle_syntax
  private_constant :LEGACY_SYNTAX_KEY

  sig {
    type_parameters(:U)
      .params(_block: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  }
  def self.with_legacy_syntax(&_block)
    thread = Thread.current
    previous = thread.thread_variable_get(LEGACY_SYNTAX_KEY)
    thread.thread_variable_set(LEGACY_SYNTAX_KEY, true)
    yield
  ensure
    thread&.thread_variable_set(LEGACY_SYNTAX_KEY, previous)
  end

  sig { returns(T::Boolean) }
  def self.legacy_syntax?
    Thread.current.thread_variable_get(LEGACY_SYNTAX_KEY) == true
  end

  # Relocatable cellar using placeholders, e.g. `@@HOMEBREW_PREFIX@@`.
  # Requires relocating text files and binaries.
  ANY_CELLAR = :any

  # Relocatable cellar using placeholders, e.g. `@@HOMEBREW_PREFIX@@`.
  # Does not need to relocate binaries but still relocates text files.
  ANY_SKIP_RELOCATION_CELLAR = :any_skip_relocation

  RELOCATABLE_CELLARS = T.let([ANY_CELLAR, ANY_SKIP_RELOCATION_CELLAR].freeze, T::Array[Symbol])

  sig { returns(T.nilable(Tap)) }
  attr_accessor :tap

  sig { returns(Utils::Bottles::Collector) }
  attr_reader :collector

  sig { returns(T::Hash[Symbol, T.untyped]) }
  attr_reader :root_url_specs

  sig { returns(String) }
  attr_reader :repository

  sig { void }
  def initialize
    @rebuild = T.let(0, Integer)
    @repository = T.let(Homebrew::DEFAULT_REPOSITORY, String)
    @collector = T.let(Utils::Bottles::Collector.new, Utils::Bottles::Collector)
    @root_url_specs = T.let({}, T::Hash[Symbol, T.untyped])
    @root_url = T.let(nil, T.nilable(String))
    @legacy_cellar = T.let(nil, T.nilable(T.any(Symbol, String)))
  end

  sig { params(val: T.nilable(Integer)).returns(Integer) }
  def rebuild(val = nil)
    val.nil? ? @rebuild : @rebuild = val
  end

  sig { params(var: T.nilable(String), specs: T::Hash[Symbol, T.untyped]).returns(String) }
  def root_url(var = nil, specs = {})
    if var.nil?
      @root_url ||= if (github_packages_url = GitHubPackages.root_url_if_match(Homebrew::EnvConfig.bottle_domain))
        github_packages_url
      else
        Homebrew::EnvConfig.bottle_domain
      end
    else
      @root_url = if (github_packages_url = GitHubPackages.root_url_if_match(var))
        github_packages_url
      else
        var
      end
      @root_url_specs.merge!(specs)
      @root_url
    end
  end

  sig { override.params(other: BasicObject).returns(T::Boolean) }
  def ==(other)
    case other
    when self.class
      rebuild == other.rebuild && collector == other.collector &&
        root_url == other.root_url && root_url_specs == other.root_url_specs && tap == other.tap
    else false
    end
  end
  alias eql? ==

  sig { params(tag: Utils::Bottles::Tag).returns(T.any(Symbol, String)) }
  def tag_to_cellar(tag = Utils::Bottles.tag)
    spec = collector.specification_for(tag)
    if spec.present?
      spec.cellar
    else
      tag.default_cellar
    end
  end

  sig {
    params(tag: Utils::Bottles::Tag, built_prefix: T.nilable(String), padded_prefix: T::Boolean)
      .returns(T::Boolean)
  }
  def compatible_locations?(tag: Utils::Bottles.tag, built_prefix: nil, padded_prefix: false)
    return false if padded_prefix && built_prefix.nil?

    cellar = padded_prefix ? "#{built_prefix}/Cellar" : tag_to_cellar(tag)

    return true if RELOCATABLE_CELLARS.include?(cellar)

    prefix = Pathname(cellar.to_s).parent.to_s

    # Raw prefix strings are patched in place, so the byte length decides.
    relocatable = !Homebrew::EnvConfig.no_relocate_build_prefix?
    cellar_relocatable = relocatable && cellar.to_s.bytesize >= HOMEBREW_CELLAR.to_s.bytesize
    prefix_relocatable = relocatable && prefix.bytesize >= HOMEBREW_PREFIX.to_s.bytesize

    compatible_cellar = cellar == HOMEBREW_CELLAR.to_s || cellar_relocatable
    compatible_prefix = prefix == HOMEBREW_PREFIX.to_s || prefix_relocatable

    compatible_cellar && compatible_prefix
  end

  # Does the {Bottle} this {BottleSpecification} belongs to need to be relocated?
  #
  # This will always return false on Linux unless a `tab` is provided that
  # reports the bottle was built with Homebrew 5.1.15 or newer. The caller must
  # make sure that the provided `tab` is for the requested `tag`.
  sig { params(tag: Utils::Bottles::Tag, tab: T.nilable(Tab)).returns(T::Boolean) }
  def skip_relocation?(tag: Utils::Bottles.tag, tab: nil)
    spec = collector.specification_for(tag)
    spec&.cellar == ANY_SKIP_RELOCATION_CELLAR
  end

  sig { params(tag: Utils::Bottles::Tag, no_older_versions: T::Boolean).returns(T::Boolean) }
  def tag?(tag, no_older_versions: false)
    collector.tag?(tag, no_older_versions:)
  end

  # Checksum methods in the DSL's bottle block take
  # a Hash, which indicates the platform the checksum applies on.
  # Example bottle block syntax:
  # bottle do
  #  sha256 cellar: :any_skip_relocation, big_sur: "69489ae397e4645..."
  #  sha256 cellar: :any, monterey: "449de5ea35d0e94..."
  # end
  sig { params(hash: T::Hash[T.any(Symbol, String), T.any(String, Symbol)]).void }
  def sha256(hash)
    sha256_regex = /^[a-f0-9]{64}$/i

    legacy = hash.find do |key, value|
      key.is_a?(String) && key.match?(sha256_regex) && value.is_a?(Symbol)
    end
    if legacy
      # Historical formula loading needs to cross the 2021 bottle syntax wall,
      # while current formulae must continue to reject the removed DSL.
      raise LegacyDSLError.new(:sha256, hash) unless self.class.legacy_syntax?

      digest, tag = legacy
    else
      # find new `sha256 big_sur: "69489ae397e4645..."` format
      tag, digest = hash.find do |key, value|
        key.is_a?(Symbol) && value.is_a?(String) && value.match?(sha256_regex)
      end
    end

    odie "Invalid sha256 hash: #{digest}" if !tag || !digest

    tag = Utils::Bottles::Tag.from_symbol(T.cast(tag, Symbol))

    cellar = hash[:cellar] || @legacy_cellar || tag.default_cellar

    collector.add(tag, checksum: Checksum.new(digest.to_s), cellar:)
  end

  sig { params(value: T.any(Symbol, String)).returns(T.any(Symbol, String)) }
  def cellar(value)
    raise LegacyDSLError.new(:cellar, value) unless self.class.legacy_syntax?

    @legacy_cellar = value
  end

  sig {
    params(tag: Utils::Bottles::Tag, no_older_versions: T::Boolean)
      .returns(T.nilable(Utils::Bottles::TagSpecification))
  }
  def tag_specification_for(tag, no_older_versions: false)
    collector.specification_for(tag, no_older_versions:)
  end

  sig { returns(T::Array[{ "tag" => Symbol, "digest" => Checksum, "cellar" => T.any(Symbol, String) }]) }
  def checksums
    tags = collector.tags.sort_by do |tag|
      version = tag.to_macos_version
      # Give `arm64` bottles a higher priority so they are first.
      priority = (tag.arch == :arm64) ? 3 : 2
      "#{priority}.#{version}_#{tag}"
    rescue MacOSVersion::Error
      # Sort non-macOS tags below macOS tags, and arm64 tags before other tags.
      priority = (tag.arch == :arm64) ? 1 : 0
      "#{priority}.#{tag}"
    end
    tags.reverse.map do |tag|
      spec = collector.specification_for(tag)
      odie "Specification for tag #{tag} is nil" if spec.nil?
      {
        "tag"    => spec.tag.to_sym,
        "digest" => spec.checksum,
        "cellar" => spec.cellar,
      }
    end
  end
end

require "extend/os/bottle_specification"
