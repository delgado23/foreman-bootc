# Minimal stand-ins for the Foreman models that foreman/setup_local_boot_template.rb
# touches, so the script can run under plain Ruby in CI. State lives in a JSON
# file (FAKE_STATE) that is loaded before the script runs and written back when
# it exits, so consecutive runs exercise idempotency the way repeated
# `foreman-rake console` runs would.
require 'json'

STATE_PATH = ENV.fetch('FAKE_STATE')
STATE = JSON.parse(File.read(STATE_PATH))

class FakeTaxonomy
  attr_reader :id, :name
  def initialize(id, name)
    @id = id
    @name = name
  end
end

LOCATIONS = STATE['locations'].to_h { |l| [l['id'], FakeTaxonomy.new(l['id'], l['name'])] }

class FakeOrganization < FakeTaxonomy
  def initialize(id, name, location_ids)
    super(id, name)
    @location_ids = location_ids
  end

  def locations
    @location_ids.map { |i| LOCATIONS.fetch(i) }
  end
end

ORGS = STATE['organizations'].to_h { |o| [o['id'], FakeOrganization.new(o['id'], o['name'], o['location_ids'])] }

class FakeRelation
  def initialize(rows)
    @rows = rows
  end

  def find_by(**attrs)
    @rows.find { |r| attrs.all? { |k, v| r.public_send(k) == v } }
  end

  def find_by!(**attrs)
    find_by(**attrs) || raise("record not found: #{attrs}")
  end
end

class User
  Row = Struct.new(:login)
  class << self
    attr_accessor :current
  end

  def self.unscoped
    FakeRelation.new([Row.new('admin')])
  end
end

class Organization
  def self.unscoped
    FakeRelation.new(ORGS.values)
  end
end

class ProvisioningTemplate
  attr_accessor :name, :template, :template_kind, :snippet, :locked
  attr_reader :organizations, :locations

  def initialize(name:)
    @name = name
    @organizations = []
    @locations = []
    @new_record = true
  end

  def self.unscoped
    FakeRelation.new(ALL)
  end

  def organizations=(list)
    @organizations = list.to_a
  end

  def locations=(list)
    @locations = list.to_a
  end

  def save!
    raise "refusing to modify locked template #{name}" if locked && !@new_record && STATE['templates'].any? { |t| t['name'] == name && t['locked'] }
    ALL << self if @new_record
    @new_record = false
    true
  end

  def to_row
    { 'name' => name, 'template' => template, 'template_kind' => template_kind, 'snippet' => snippet,
      'locked' => locked, 'organization_ids' => organizations.map(&:id), 'location_ids' => locations.map(&:id) }
  end

  private

  def load_row(t)
    @name = t['name']
    @template = t['template']
    @template_kind = t['template_kind']
    @snippet = t['snippet']
    @locked = t['locked']
    @organizations = t['organization_ids'].map { |i| ORGS.fetch(i) }
    @locations = t['location_ids'].map { |i| LOCATIONS.fetch(i) }
    @new_record = false
  end

  public

  # Built last: the class body runs top to bottom, so load_row must exist first.
  ALL = STATE['templates'].map do |t|
    pt = allocate
    pt.send(:load_row, t)
    pt
  end
end

class Setting
  def self.[](name)
    STATE['settings'][name.to_s]
  end

  def self.[]=(name, value)
    STATE['settings'][name.to_s] = value
  end
end

class Parameter
  Row = Struct.new(:name, :type, :reference_id, :value)

  def self.where(name:)
    names = Array(name)
    STATE['parameters'].map { |p| Row.new(p['name'], p['type'], p['reference_id'], p['value']) }.select { |p| names.include?(p.name) }
  end
end

at_exit do
  STATE['templates'] = ProvisioningTemplate::ALL.map(&:to_row)
  File.write(STATE_PATH, JSON.pretty_generate(STATE))
end
