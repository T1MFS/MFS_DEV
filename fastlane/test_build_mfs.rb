require "minitest/autorun"
require "base64"
require "shellwords"

ENV["TEAMID"] = "TESTTEAM"
ENV.delete("CI")

module SharedValues
  MATCH_PROVISIONING_PROFILE_MAPPING = :mapping
end

module Actions
  def self.lane_context
    { mapping: { "com.TESTTEAM.mfs" => "test profile" } }
  end
end

class FastfileHarness
  attr_reader :calls

  def initialize
    @calls = {}
    @lanes = {}
    instance_eval(File.read(File.join(__dir__, "Fastfile")), File.join(__dir__, "Fastfile"))
  end

  def default_platform(*) = nil
  def platform(*, &block) = instance_exec(&block)
  def desc(*) = nil
  def lane(name, &block) = @lanes[name] = block
  def run(name) = instance_exec(&@lanes.fetch(name))

  def method_missing(name, *args, **kwargs)
    @calls[name] = kwargs
    return 1 if name == :latest_testflight_build_number
    return {} if name == :app_store_connect_api_key
    return nil if %i[update_project_team increment_build_number match update_code_signing_settings gym copy_artifacts].include?(name)

    super
  end
end

class BuildMfsSigningTest < Minitest::Test
  def test_build_number_updates_the_generated_plist_build_setting
    fastfile = FastfileHarness.new
    fastfile.run(:build_mfs)
    increment = fastfile.calls.fetch(:increment_build_number)
    assert_equal 2, increment[:build_number]
    assert_equal true, increment[:skip_info_plist]

    project = File.read(File.join(__dir__, "..", "MFS.xcodeproj", "project.pbxproj"))
    %w[A1000000000000000000000C A1000000000000000000000D].each do |id|
      settings = project.match(/#{id} \/\* (?:Debug|Release) \*\/ = \{.*?buildSettings = \{(.*?)\n\s*\};/m)
      refute_nil settings
      assert_match(/CURRENT_PROJECT_VERSION = \d+;/, settings[1])
      assert_match(/MARKETING_VERSION = \d+\.\d+(?:\.\d+)?;/, settings[1])
      assert_includes settings[1], 'VERSIONING_SYSTEM = "apple-generic";'
    end
  end

  def test_signing_overrides_are_scoped_to_the_app
    fastfile = FastfileHarness.new
    fastfile.run(:build_mfs)
    signing = fastfile.calls.fetch(:update_code_signing_settings)
    assert_equal ["MFS"], signing[:targets]
    assert_equal "com.TESTTEAM.mfs", signing[:bundle_identifier]
    assert_equal "test profile", signing[:profile_name]

    args = Shellwords.split(fastfile.calls.fetch(:gym)[:xcargs])
    assert_includes args, "MFS_CODE_SIGNING_ALLOWED=YES"
    refute args.any? { |arg| arg.start_with?("PRODUCT_BUNDLE_IDENTIFIER=", "CODE_SIGNING_ALLOWED=") }
  end

  def test_app_signing_is_disabled_by_default_in_both_configurations
    project = File.read(File.join(__dir__, "..", "MFS.xcodeproj", "project.pbxproj"))
    %w[A1000000000000000000000E A1000000000000000000000F].each do |id|
      settings = project.match(/#{id} \/\* (?:Debug|Release) \*\/ = \{.*?buildSettings = \{(.*?)\n\s*\};/m)
      refute_nil settings
      assert_includes settings[1], 'CODE_SIGNING_ALLOWED = "$(MFS_CODE_SIGNING_ALLOWED)";'
      assert_includes settings[1], "MFS_CODE_SIGNING_ALLOWED = NO;"
    end
  end
end
