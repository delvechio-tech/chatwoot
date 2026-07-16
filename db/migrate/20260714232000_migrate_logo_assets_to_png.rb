class MigrateLogoAssetsToPng < ActiveRecord::Migration[7.1]
  PNG_URLS = {
    'LOGO'           => '/brand-assets/logo.png?v=2.0',
    'LOGO_THUMBNAIL' => '/brand-assets/logo_thumbnail.png?v=2.0',
    'LOGO_DARK'      => '/brand-assets/logo_dark.png?v=2.0'
  }.freeze

  SVG_URLS = {
    'LOGO'           => '/brand-assets/logo.svg?v=1.1',
    'LOGO_THUMBNAIL' => '/brand-assets/logo_thumbnail.svg?v=1.1',
    'LOGO_DARK'      => '/brand-assets/logo_dark.svg?v=1.1'
  }.freeze

  def up
    PNG_URLS.each do |name, new_value|
      InstallationConfig.find_by(name: name)&.update!(value: new_value)
    end
    GlobalConfig.clear_cache
  end

  def down
    SVG_URLS.each do |name, old_value|
      InstallationConfig.find_by(name: name)&.update!(value: old_value)
    end
    GlobalConfig.clear_cache
  end
end
