class DisableDisplayManifest < ActiveRecord::Migration[7.1]
  def up
    InstallationConfig.find_by(name: 'DISPLAY_MANIFEST')&.update!(value: false)
    GlobalConfig.clear_cache
  end

  def down
    InstallationConfig.find_by(name: 'DISPLAY_MANIFEST')&.update!(value: true)
    GlobalConfig.clear_cache
  end
end
