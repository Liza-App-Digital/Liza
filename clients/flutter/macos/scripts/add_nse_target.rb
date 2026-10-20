#!/usr/bin/env ruby
# frozen_string_literal: true

# Идемпотентно добавляет Notification Service Extension target в macOS
# Runner.xcodeproj. Запуск:
#
#   cd clients/flutter/macos && ruby scripts/add_nse_target.rb
#
# Что делает:
#   - создаёт target "NotificationServiceExtensionMacOS" (productType
#     com.apple.product-type.app-extension);
#   - подцепляет NotificationService.swift из iOS NSE (общий файл, чтобы
#     не дублировать код между iOS и macOS);
#   - подцепляет Info.plist и entitlements из macos/Notification Service Extension/;
#   - встраивает .appex в Runner.app через Copy Files build phase
#     (destination Plugins, subfolder /Contents/PlugIns);
#   - добавляет dependency Runner → NSE.
#
# Скрипт безопасно перезапускать: если target уже существует, ничего не делает.
#
# ⚠️ С 2026-10-19 appex в Liza.app НЕ встраивается и Runner от него не зависит:
# расширение не стартовало ни на одном Маке, а usernoted через 120 с повторно
# показывал баннер (howItWoks/pushes/pushes.md §24, страж
# test/native/macos_nse_not_embedded_test.dart). Перезапуск скрипта вернёт
# встраивание — не запускать, пока старт NSE не починен.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Runner.xcodeproj', __dir__)
TARGET_NAME = 'NotificationServiceExtensionMacOS'
PRODUCT_NAME = 'NotificationServiceExtensionMacOS'
# Значения берутся из профиля аккаунта (build-profiles/<account>.env),
# иначе повторный запуск скрипта откатит bundle id на старый аккаунт.
# Дефолты — старый аккаунт, чтобы скрипт работал без окружения.
BUNDLE_BASE = ENV.fetch('LIZA_BUNDLE_ID', 'ru.prodamus.liza')
NSE_SUFFIX = ENV.fetch('LIZA_BUNDLE_SUFFIX_NSE_MACOS', '.NotificationServiceExtensionMacOS')
BUNDLE_ID = "#{BUNDLE_BASE}#{NSE_SUFFIX}"
DEPLOYMENT_TARGET = '12.2'

project = Xcodeproj::Project.open(PROJECT_PATH)

def attach_xcconfig(project, target)
  # Удаляем старые ссылки на NSE-Common.xcconfig и пустую группу Configs,
  # если предыдущий запуск создал их с неверным path. Скрипт должен быть
  # идемпотентным — пересоздаём с нуля.
  project.files.select { |f| f.path&.include?('NSE-Common.xcconfig') }.each do |f|
    f.remove_from_project
  end
  nse_group = project.main_group.find_subpath('Notification Service Extension', true)
  configs_group = nse_group.children.find { |g| g.respond_to?(:name) && g.name == 'Configs' }
  configs_group&.remove_from_project

  ref = nse_group.new_file('NSE-Common.xcconfig')
  # source_tree = "<group>" + path = "NSE-Common.xcconfig" → Xcode сам
  # соберёт полный путь "Notification Service Extension/NSE-Common.xcconfig"
  # из path родительской группы.
  ref.source_tree = '<group>'
  ref.path = 'NSE-Common.xcconfig'

  target.build_configurations.each do |config|
    config.base_configuration_reference = ref
  end
end

RELEASE_PROFILE_NAME = ENV.fetch('LIZA_PROFILE_MACOS_NSE', 'Liza NSE macOS Production')
# Debug тоже manual (решение 2026-08-13): релизы режутся локально,
# детерминированность подписи важнее удобства Automatic.
DEBUG_PROFILE_NAME = ENV.fetch('LIZA_PROFILE_MACOS_NSE_DEV', 'Liza NSE macOS Development')
# Совпадает с Runner Release CODE_SIGN_IDENTITY (3rd Party Mac Developer Application
# для PRODAMUS, OOO). NSE и родитель должны быть подписаны одним сертификатом.
RELEASE_CODE_SIGN_IDENTITY = ENV.fetch('LIZA_CERT_MAC_APP_SHA1', '9BBDCC8EDD4A385A4BAD7E09460962BE9AF5BD08')

# Применяет настройки подписи в зависимости от типа конфигурации:
# - Debug/Profile: development-профиль и сертификат;
# - Release: distribution-сертификат + App Store профиль.
# Оба варианта — Manual: Automatic не используется нигде.
def apply_signing(bs, release:)
  bs['DEVELOPMENT_TEAM'] = ENV.fetch('LIZA_TEAM_ID', 'H77D732S9L')
  if release
    bs['CODE_SIGN_STYLE'] = 'Manual'
    bs['CODE_SIGN_IDENTITY'] = RELEASE_CODE_SIGN_IDENTITY
    bs['PROVISIONING_PROFILE_SPECIFIER'] = RELEASE_PROFILE_NAME
    bs['PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]'] = RELEASE_PROFILE_NAME
  else
    bs['CODE_SIGN_STYLE'] = 'Manual'
    bs['CODE_SIGN_IDENTITY'] = 'Apple Development'
    bs['PROVISIONING_PROFILE_SPECIFIER'] = DEBUG_PROFILE_NAME
    bs['PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]'] = DEBUG_PROFILE_NAME
  end
end

existing = project.targets.find { |t| t.name == TARGET_NAME }
if existing
  # Идемпотентно обновляем build settings (подпись, deployment target, module).
  existing.build_configurations.each do |config|
    bs = config.build_settings
    bs['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
    bs['PRODUCT_NAME'] = PRODUCT_NAME
    bs['PRODUCT_MODULE_NAME'] = PRODUCT_NAME
    bs['CODE_SIGN_ENTITLEMENTS'] = 'Notification Service Extension/Notification Service Extension.entitlements'
    bs['INFOPLIST_FILE'] = 'Notification Service Extension/Info.plist'
    bs['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
    bs['SWIFT_VERSION'] = '5.0'
    bs['SKIP_INSTALL'] = 'YES'
    apply_signing(bs, release: config.name == 'Release')
  end
  attach_xcconfig(project, existing)
  project.save
  puts "Target '#{TARGET_NAME}' уже есть — обновили build settings (подпись + module + xcconfig)."
  exit 0
end

runner = project.targets.find { |t| t.name == 'Runner' } or
  raise 'Не найден target Runner в Runner.xcodeproj'

# Создаём app-extension target.
nse = project.new_target(
  :app_extension,
  TARGET_NAME,
  :osx,
  DEPLOYMENT_TARGET,
  nil,
  :swift,
)
nse.product_name = PRODUCT_NAME

# Build settings.
nse.build_configurations.each do |config|
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  bs['PRODUCT_NAME'] = PRODUCT_NAME
  bs['PRODUCT_MODULE_NAME'] = PRODUCT_NAME
  bs['CODE_SIGN_ENTITLEMENTS'] = 'Notification Service Extension/Notification Service Extension.entitlements'
  bs['INFOPLIST_FILE'] = 'Notification Service Extension/Info.plist'
  bs['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  bs['SWIFT_VERSION'] = '5.0'
  bs['SKIP_INSTALL'] = 'YES'
  bs['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/../../../../Frameworks',
    '@executable_path/../../Frameworks',
  ]
  bs['ALWAYS_SEARCH_USER_PATHS'] = 'NO'
  bs['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  bs['ENABLE_BITCODE'] = 'NO'
  # Communication Notification API + StringCatalog требуют 12.0, у нас 12.2.
  bs['CURRENT_PROJECT_VERSION'] = '1'
  bs['MARKETING_VERSION'] = '1.0'
  apply_signing(bs, release: config.name == 'Release')
end

# Группа в навигаторе Xcode.
main_group = project.main_group
nse_group = main_group.find_subpath('Notification Service Extension', true)
nse_group.set_source_tree('<group>')
nse_group.set_path('Notification Service Extension')

# Общий код с iOS NSE (один источник истины).
shared_swift_relative = '../../ios/Notification Service Extension/NotificationService.swift'
swift_file = nse_group.new_file(shared_swift_relative)
nse.add_file_references([swift_file])

# Info.plist и entitlements — только ссылка в навигаторе, в build phases
# не добавляются (Xcode подхватывает по build settings).
nse_group.new_file('Info.plist')
nse_group.new_file('Notification Service Extension.entitlements')

# Resources phase — копируем liza_ding.aiff (NSE должен иметь свой звук в бандле).
sound_ref = project.files.find { |f| f.path == 'liza_ding.aiff' }
if sound_ref
  nse.resources_build_phase.add_file_reference(sound_ref)
end

# Embed extension в Runner.app.
embed_phase = runner.copy_files_build_phases.find do |phase|
  phase.symbol_dst_subfolder_spec == :plug_ins
end
embed_phase ||= runner.new_copy_files_build_phase('Embed App Extensions').tap do |phase|
  phase.symbol_dst_subfolder_spec = :plug_ins
  phase.run_only_for_deployment_postprocessing = '0'
end

unless embed_phase.files_references.include?(nse.product_reference)
  build_file = embed_phase.add_file_reference(nse.product_reference)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

# Dependency: Runner ждёт сборку NSE.
runner.add_dependency(nse) unless runner.dependencies.any? { |d| d.target == nse }

attach_xcconfig(project, nse)

project.save
puts "Добавлен target '#{TARGET_NAME}'. Проверь сборку: cd .. && flutter build macos --debug"
