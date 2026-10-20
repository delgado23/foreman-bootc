# Minimal stand-ins for the Foreman models that the foreman/ scripts under test
# (setup_local_boot_template.rb, setup_proxmox_firmware.rb) touch, so the script can run under plain Ruby in CI. State lives in a JSON
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

LOCATIONS = STATE.fetch('locations', []).to_h { |l| [l['id'], FakeTaxonomy.new(l['id'], l['name'])] }

class FakeOrganization < FakeTaxonomy
  def initialize(id, name, location_ids)
    super(id, name)
    @location_ids = location_ids
  end

  def locations
    @location_ids.map { |i| LOCATIONS.fetch(i) }
  end
end

ORGS = STATE.fetch('organizations', []).to_h { |o| [o['id'], FakeOrganization.new(o['id'], o['name'], o['location_ids'])] }

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
  ALL = STATE.fetch('templates', []).map do |t|
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
    STATE.fetch('parameters', []).map { |p| Row.new(p['name'], p['type'], p['reference_id'], p['value']) }.select { |p| names.include?(p.name) }
  end
end

# --- setup_proxmox_firmware.rb ----------------------------------------------

# Inside Foreman this is a real database transaction; like the real thing, the
# fake undoes the writes if the block raises (the state is restored from a
# snapshot).
module ActiveRecord
  class Base
    def self.transaction
      snapshot = Marshal.load(Marshal.dump(STATE))
      yield
    rescue StandardError
      STATE.replace(snapshot)
      raise
    end
  end
end

# ActiveSupport provides Hash#deep_dup inside Foreman.
class Hash
  def deep_dup
    Marshal.load(Marshal.dump(self))
  end
end

SETTINGS = { version: STATE.fetch('foreman_version', '5.0.1') }.freeze

if STATE.key?('plugin_version')
  Gem.loaded_specs['foreman_fog_proxmox'] = Gem::Specification.new do |spec|
    spec.name = 'foreman_fog_proxmox'
    spec.version = STATE['plugin_version']
  end
else
  Gem.loaded_specs.delete('foreman_fog_proxmox')
end

class ComputeResource
  Row = Struct.new(:id, :name)
  def self.unscoped
    FakeRelation.new(STATE.fetch('compute_resources', []).map { |c| Row.new(c['id'], c['name']) })
  end
end

class ComputeProfile
  Row = Struct.new(:id, :name)
  def self.unscoped
    FakeRelation.new(STATE.fetch('compute_profiles', []).map { |c| Row.new(c['id'], c['name']) })
  end
end

class ComputeAttribute
  attr_reader :compute_resource_id, :compute_profile_id
  attr_accessor :vm_attrs

  def initialize(row)
    @row = row
    @compute_resource_id = row['compute_resource_id']
    @compute_profile_id = row['compute_profile_id']
    @vm_attrs = row['vm_attrs']
  end

  def save!
    @row['vm_attrs'] = @vm_attrs
    true
  end

  ALL = STATE.fetch('compute_attributes', []).map { |r| new(r) }

  def self.unscoped
    FakeRelation.new(ALL)
  end
end

class Hostgroup
  attr_reader :id, :title, :parent_id
  attr_writer :pxe_loader

  def initialize(row)
    @row = row
    @id = row['id']
    @title = row['title']
    @parent_id = row['parent_id']
    @pxe_loader = row['pxe_loader']
  end

  def read_attribute(name)
    raise "unexpected attribute #{name}" unless name.to_sym == :pxe_loader
    @pxe_loader
  end

  # The effective loader: an empty value inherits from the parent.
  def pxe_loader
    return @pxe_loader unless @pxe_loader.to_s.empty?
    parent = ALL.find { |h| h.id == parent_id }
    parent&.pxe_loader
  end

  def subtree_ids
    [id] + ALL.select { |h| h.parent_id == id }.flat_map(&:subtree_ids)
  end

  def save!
    raise 'simulated host group save failure' if ENV['FAIL_HOSTGROUP_SAVE'] == '1'
    @row['pxe_loader'] = @pxe_loader
    true
  end

  ALL = STATE.fetch('hostgroups', []).map { |r| new(r) }

  def self.unscoped
    Finder.new
  end

  class Finder
    def find(id)
      ALL.find { |h| h.id == id } || raise("hostgroup #{id} not found")
    end
  end
end

module Host
  class Managed
    Row = Struct.new(:name, :hostgroup_id, :stored_loader) do
      def hostgroup
        Hostgroup::ALL.find { |h| h.id == hostgroup_id }
      end

      def pxe_loader
        stored_loader.to_s.empty? ? hostgroup&.pxe_loader : stored_loader
      end
    end

    class Query
      def initialize(rows)
        @rows = rows
      end

      def where(hostgroup_id:, pxe_loader:)
        Query.new(@rows.select { |r| Array(hostgroup_id).include?(r.hostgroup_id) && Array(pxe_loader).include?(r.stored_loader) })
      end

      def order(field)
        Query.new(@rows.sort_by { |r| r.public_send(field) })
      end

      def each(&block)
        @rows.each(&block)
      end
    end

    def self.unscoped
      Query.new(STATE.fetch('hosts', []).map { |h| Row.new(h['name'], h['hostgroup_id'], h['pxe_loader']) })
    end
  end
end

at_exit do
  STATE['templates'] = ProvisioningTemplate::ALL.map(&:to_row) if STATE.key?('templates')
  File.write(STATE_PATH, JSON.pretty_generate(STATE))
end
