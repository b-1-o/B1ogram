# Biogram iOS app branding

## Home Screen name

The main application uses the `TelegramInfoPlist` fragment in `Telegram/BUILD`. Its `CFBundleDisplayName` and `CFBundleName` must both be `Biogram`. The separate `AppNameInfoPlist` fragment is not attached to the main `ios_application` target, so changing only that fragment does not change the installed app name.

Keep the Bazel target name `//Telegram:Swiftgram` for now: `build-system/Make/Make.py` builds that target explicitly. Renaming the target is a separate change and can break CI scripts.

## App icon

The main app currently uses the Apple Icon Composer bundle, not the legacy asset catalog:

- Icon Composer file: `Telegram/Telegram-iOS/Swiftgram.icon/`
- Layer manifest: `Telegram/Telegram-iOS/Swiftgram.icon/icon.json`
- Current image layer: `Telegram/Telegram-iOS/Swiftgram.icon/Assets/Default@3x 2.svg`

The root-level asset catalog at `Telegram/Telegram-iOS/DefaultAppIcon.xcassets/` is not used by the main target's current `app_icons` attribute. Replacing its PNG alone will not change the installed icon.

### Replace the existing image

For a custom SVG, replace the contents of `Assets/Default@3x 2.svg` and keep its filename unchanged. The current manifest already references it.

For a custom PNG, copy the image (preferably 1024×1024 and without rounded corners) to:

```
Telegram/Telegram-iOS/Swiftgram.icon/Assets/Biogram.png
```

Then edit `Telegram/Telegram-iOS/Swiftgram.icon/icon.json` and change the layer's `image-name` from `Default@3x 2.svg` to `Biogram.png`. If the PNG is already a complete, flattened icon design and should not receive Liquid Glass processing, set that layer's `glass` value to `false`. For artwork intentionally designed as a foreground layer, keep the existing material settings and preview it in Apple's Icon Composer before shipping.

The directory name `Swiftgram.icon` is currently referenced by `composer_icon_folders = ["Swiftgram"]` in `Telegram/BUILD`. Keep the directory and manifest together unless you also update that Bazel setting.

## Reinstalling

After a new IPA is built, install that new IPA. iOS may continue showing the previously installed app's icon until the new build is installed; the icon is embedded in the app bundle and is not downloaded from a server.
