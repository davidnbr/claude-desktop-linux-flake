{ lib, stdenvNoCC, fetchurl, electron, p7zip, icoutils, nodePackages
, imagemagick, makeDesktopItem, makeWrapper, patchy-cnb, perl, xdg-utils
, libcanberra-gtk3, mesa, libGL, }:
let
  pname = "claude-desktop";
  # To update to a new version:
  # 1. Update the version number below
  # 2. Update the hash with the new SHA256 (or set to an empty string and let Nix calculate it)
  # 3. Run: nix build .#claude-desktop --impure
  # 4. If hash is wrong, Nix will show the correct hash - update it here
  #
  # Version history: Check https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/
  # Current releases can be monitored from the official Windows/Mac downloads
  version = "0.12.112";
  srcExe = fetchurl {
    # NOTE: `?v=0.10.0` doesn't actually request a specific version. It's only being used here as a cache buster.
    url =
      "https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe?v=${version}";
    hash = "sha256-Sn/lvMlfKd7b/utFvCxrkWNDJTug4OOSA4lo9YV8aqk=";
  };
in stdenvNoCC.mkDerivation rec {
  inherit pname version;

  src = ./.;

  nativeBuildInputs =
    [ p7zip nodePackages.asar makeWrapper imagemagick icoutils perl ];

  desktopItem = makeDesktopItem {
    name = "claude-desktop";
    exec = "claude-desktop %u";
    icon = "claude";
    type = "Application";
    terminal = false;
    desktopName = "Claude";
    genericName = "Claude Desktop";
    categories = [ "Office" "Utility" ];
    mimeTypes = [ "x-scheme-handler/claude" ];
  };

  buildPhase = ''
    runHook preBuild

    # Create temp working directory
    mkdir -p $TMPDIR/build
    cd $TMPDIR/build

    # Extract installer exe, and nupkg within it
    7z x -y ${srcExe}
    # Find and extract the nupkg file (filename may vary)
    ls -la
    NUPKG_FILE=$(find . -name "*.nupkg" -type f | head -1)
    if [ -z "$NUPKG_FILE" ]; then
      echo "Error: No .nupkg file found"
      find . -name "*Claude*" -o -name "*.nupkg" -o -name "*.zip"
      exit 1
    fi
    echo "Found nupkg file: $NUPKG_FILE"
    7z x -y "$NUPKG_FILE"

    # Package the icons from claude.exe
    wrestool -x -t 14 lib/net45/claude.exe -o claude.ico
    icotool -x claude.ico

    for size in 16 24 32 48 64 256; do
      mkdir -p $TMPDIR/build/icons/hicolor/"$size"x"$size"/apps
      install -Dm 644 claude_*"$size"x"$size"x32.png \
        $TMPDIR/build/icons/hicolor/"$size"x"$size"/apps/claude.png
    done

    rm claude.ico

    # Process app.asar files
    # We need to replace claude-native-bindings.node in both the
    # app.asar package and .unpacked directory
    mkdir -p electron-app
    cp "lib/net45/resources/app.asar" electron-app/
    cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

    cd electron-app
    asar extract app.asar app.asar.contents

    echo "Using search pattern: '$TARGET_PATTERN' within search base: '$SEARCH_BASE'"
    SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
    TARGET_PATTERN="MainWindowPage-*.js"

    echo "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
    # Find the target file recursively (ensure only one matches)
    TARGET_FILES=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN")
    # Count non-empty lines to get the number of files found
    NUM_FILES=$(echo "$TARGET_FILES" | grep -c .)
    echo "Found $NUM_FILES matching files"
    echo "Target files: $TARGET_FILES"

    echo "##############################################################"
    echo "Removing "'!'" from 'if ("'!'"isWindows && isMainWindow) return null;'"
    echo "detection flag to to enable title bar"

    echo "Current working directory: '$PWD'"

    echo "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
    # Find the target file recursively (ensure only one matches)
    if [ "$NUM_FILES" -eq 0 ]; then
      echo "Error: No file matching '$TARGET_PATTERN' found within '$SEARCH_BASE'." >&2
      exit 1
    elif [ "$NUM_FILES" -gt 1 ]; then
      echo "Error: Expected exactly one file matching '$TARGET_PATTERN' within '$SEARCH_BASE', but found $NUM_FILES." >&2
      echo "Found files:" >&2
      echo "$TARGET_FILES" >&2
      exit 1
    else
      # Exactly one file found
      TARGET_FILE="$TARGET_FILES" # Assign the found file path
      echo "Found target file: $TARGET_FILE"

      echo "Attempting to replace patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE..."
      perl -i -pe \
        's{if\(\s*!\s*(\w+)\s*&&\s*(\w+)\s*\)}{if($1 && $2)}g' \
        "$TARGET_FILE"

      # Verification: Check if the original pattern structure still exists
      if ! grep -q -E '!\w+&&\w+' "$TARGET_FILE"; then
        echo "Successfully replaced patterns like '!VAR1&&VAR2' with 'VAR1&&VAR2' in $TARGET_FILE"
      else
        echo "Warning: Some instances of '!VAR1&&VAR2' might still exist in $TARGET_FILE." >&2
      fi        # Verification: Check if the original pattern structure still exists
    fi
    echo "##############################################################"

    echo "##############################################################"
    echo "Applying tray menu race condition fixes for KDE/Wayland"
    echo "Adding mutex guard and DBus cleanup delay to prevent tray menu issues"

    # Target the main build index file
    TRAY_TARGET_FILE="app.asar.contents/.vite/build/index.js"

    if [ ! -f "$TRAY_TARGET_FILE" ]; then
      echo "Warning: Tray target file not found at $TRAY_TARGET_FILE, skipping tray patches" >&2
    else
      echo "Found tray target file: $TRAY_TARGET_FILE"

      # Step 1: Extract the tray function name dynamically
      TRAY_FUNC=$(grep -oP 'on\("menuBarEnabled",\(\)=>\{\K\w+(?=\(\)\})' "$TRAY_TARGET_FILE" || echo "")

      if [ -z "$TRAY_FUNC" ]; then
        echo "Warning: Could not find tray function, skipping tray patches" >&2
      else
        echo "Found tray function: $TRAY_FUNC"

        # Step 2: Extract the tray variable name
        TRAY_VAR=$(grep -oP "\}\);let \K\w+(?==null;(?:async )?function ''${TRAY_FUNC})" "$TRAY_TARGET_FILE" || echo "")

        if [ -z "$TRAY_VAR" ]; then
          echo "Warning: Could not find tray variable, skipping tray patches" >&2
        else
          echo "Found tray variable: $TRAY_VAR"

          # Step 3: Make the tray function async
          sed -i "s/function ''${TRAY_FUNC}(){/async function ''${TRAY_FUNC}(){/g" "$TRAY_TARGET_FILE"
          echo "Made function ''${TRAY_FUNC} async"

          # Step 4: Extract first const in the function for mutex insertion point
          FIRST_CONST=$(grep -oP "async function ''${TRAY_FUNC}\(\)\{const \K\w+(?==)" "$TRAY_TARGET_FILE" | head -1 || echo "")

          if [ -n "$FIRST_CONST" ]; then
            # Step 5: Add mutex guard (prevents concurrent tray creation)
            sed -i "s/async function ''${TRAY_FUNC}(){const ''${FIRST_CONST}=/async function ''${TRAY_FUNC}(){if(''${TRAY_FUNC}._running)return;''${TRAY_FUNC}._running=true;setTimeout(()=>''${TRAY_FUNC}._running=false,500);const ''${FIRST_CONST}=/g" "$TRAY_TARGET_FILE"
            echo "Added mutex guard to prevent concurrent tray creation"
          else
            echo "Warning: Could not find first const for mutex insertion" >&2
          fi

          # Step 6: Add DBus cleanup delay (50ms pause after tray destruction)
          sed -i "s/''${TRAY_VAR}\&\&(''${TRAY_VAR}\.destroy(),''${TRAY_VAR}=null)/''${TRAY_VAR}\&\&(''${TRAY_VAR}.destroy(),''${TRAY_VAR}=null,await new Promise(r=>setTimeout(r,50)))/g" "$TRAY_TARGET_FILE"
          echo "Added DBus cleanup delay (50ms) after tray destruction"

          echo "Successfully applied tray menu race condition fixes"
        fi
      fi
    fi
    echo "##############################################################"

    # Replace native bindings
    cp ${patchy-cnb}/lib/patchy-cnb.*.node app.asar.contents/node_modules/claude-native/claude-native-binding.node
    cp ${patchy-cnb}/lib/patchy-cnb.*.node app.asar.unpacked/node_modules/claude-native/claude-native-binding.node

    # .vite/build/index.js in the app.asar expects the Tray icons to be
    # placed inside the app.asar.
    mkdir -p app.asar.contents/resources
    ls ../lib/net45/resources/
    cp ../lib/net45/resources/Tray* app.asar.contents/resources/

    # Copy i18n json files
    mkdir -p app.asar.contents/resources/i18n
    cp ../lib/net45/resources/*.json app.asar.contents/resources/i18n/

    # Repackage app.asar
    asar pack app.asar.contents app.asar

    runHook postBuild
  '';

  installPhase = ''
      runHook preInstall

      # Electron directory structure
      mkdir -p $out/lib/$pname
      cp -r $TMPDIR/build/electron-app/app.asar $out/lib/$pname/
      cp -r $TMPDIR/build/electron-app/app.asar.unpacked $out/lib/$pname/

      # Install icons
      mkdir -p $out/share/icons
      cp -r $TMPDIR/build/icons/* $out/share/icons

      # Install .desktop file
      mkdir -p $out/share/applications
      install -Dm0644 {${desktopItem},$out}/share/applications/$pname.desktop

      # Create wrapper
      # Rendering configuration for NVIDIA + GNOME Wayland
      #
      # Environment variables you can set to experiment:
      #   CLAUDE_USE_GPU=0           - Disable GPU compositing (fixes glitches, slower)
      #   CLAUDE_FORCE_XWAYLAND=1    - Run via XWayland instead of native Wayland
      #   CLAUDE_ELECTRON_FLAGS="..." - Custom Electron flags (overrides defaults)
      #
      # Default behavior: Native Wayland with WaylandWindowDecorations
      mkdir -p $out/bin
      makeWrapper ${electron}/bin/electron $out/bin/$pname \
    --add-flags "$out/lib/$pname/app.asar" \
    --add-flags "\''${CLAUDE_FORCE_XWAYLAND:+--ozone-platform=x11}" \
    --add-flags "\''${CLAUDE_FORCE_XWAYLAND:-\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations}}}" \
    --add-flags "\''${CLAUDE_USE_GPU:+--disable-gpu-compositing}" \
    --add-flags "\''${CLAUDE_ELECTRON_FLAGS}" \
    --prefix PATH : ${lib.makeBinPath [ xdg-utils ]} \
    --prefix LD_LIBRARY_PATH : ${
      lib.makeLibraryPath [ mesa libGL libcanberra-gtk3 ]
    } \
    --set GTK_PATH ${libcanberra-gtk3}/lib/gtk-3.0
      runHook postInstall
  '';

  dontUnpack = true;
  dontConfigure = true;

  meta = with lib; {
    description = "Claude Desktop for Linux";
    license = licenses.unfree;
    platforms = platforms.unix;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = pname;
  };
}
