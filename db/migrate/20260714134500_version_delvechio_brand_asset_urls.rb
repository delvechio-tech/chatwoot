class VersionDelvechioBrandAssetUrls < ActiveRecord::Migration[7.1]
  BRAND_ASSET_URLS = {
    'LOGO_THUMBNAIL' => '/brand-assets/logo_thumbnail.svg',
    'LOGO' => '/brand-assets/logo.svg',
    'LOGO_DARK' => '/brand-assets/logo_dark.svg'
  }.freeze

  def up
    BRAND_ASSET_URLS.each do |name, asset_url|
      config = InstallationConfig.find_by(name: name, value: asset_url)
      config&.update!(value: versioned(asset_url))
    end
    GlobalConfig.clear_cache
  end

  def down
    BRAND_ASSET_URLS.each do |name, asset_url|
      config = InstallationConfig.find_by(name: name, value: versioned(asset_url))
      config&.update!(value: asset_url)
    end
    GlobalConfig.clear_cache
  end

  private

  def versioned(asset_url)
    "#{asset_url}?v=1.1"
  end
end
