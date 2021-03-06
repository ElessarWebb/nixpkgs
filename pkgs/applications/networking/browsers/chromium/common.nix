{ stdenv, ninja, which

# default dependencies
, bzip2, flac, speex, libopus
, libevent, expat, libjpeg, snappy
, libpng, libxml2, libxslt, libcap
, xdg_utils, yasm, minizip, libwebp
, libusb1, pciutils, nss

, python, pythonPackages, perl, pkgconfig
, nspr, systemd, kerberos
, utillinux, alsaLib
, bison, gperf
, glib, gtk, dbus_glib
, libXScrnSaver, libXcursor, libXtst, mesa
, protobuf, speechd, libXdamage, cups

# optional dependencies
, libgcrypt ? null # gnomeSupport || cupsSupport
, libexif ? null # only needed for Chromium before version 51

# package customization
, enableSELinux ? false, libselinux ? null
, enableNaCl ? false
, enableHotwording ? false
, gnomeSupport ? false, gnome ? null
, gnomeKeyringSupport ? false, libgnome_keyring3 ? null
, proprietaryCodecs ? true
, cupsSupport ? true
, pulseSupport ? false, libpulseaudio ? null
, hiDPISupport ? false

, upstream-info
}:

buildFun:

with stdenv.lib;

let
  # The additional attributes for creating derivations based on the chromium
  # source tree.
  extraAttrs = buildFun base;

  mkGypFlags =
    let
      sanitize = value:
        if value == true then "1"
        else if value == false then "0"
        else "${value}";
      toFlag = key: value: "-D${key}=${sanitize value}";
    in attrs: concatStringsSep " " (attrValues (mapAttrs toFlag attrs));

  gypFlagsUseSystemLibs = {
    use_system_bzip2 = true;
    use_system_flac = true;
    use_system_libevent = true;
    use_system_libexpat = true;
    # XXX: System libjpeg fails to link for version 52.0.2743.10
    use_system_libjpeg = versionOlder upstream-info.version "52.0.2743.10";
    use_system_libpng = false;
    use_system_libwebp = true;
    use_system_libxml = true;
    use_system_opus = true;
    use_system_snappy = true;
    use_system_speex = true;
    use_system_stlport = true;
    use_system_xdg_utils = true;
    use_system_yasm = true;
    use_system_zlib = false;
    use_system_protobuf = false; # needs newer protobuf

    use_system_harfbuzz = false;
    use_system_icu = false; # Doesn't support ICU 52 yet.
    use_system_libusb = false; # http://crbug.com/266149
    use_system_skia = false;
    use_system_sqlite = false; # http://crbug.com/22208
    use_system_v8 = false;
  };

  opusWithCustomModes = libopus.override {
    withCustomModes = true;
  };

  defaultDependencies = [
    bzip2 flac speex opusWithCustomModes
    libevent expat libjpeg snappy
    libpng libxml2 libxslt libcap
    xdg_utils yasm minizip libwebp
    libusb1
  ];

  # build paths and release info
  packageName = extraAttrs.packageName or extraAttrs.name;
  buildType = "Release";
  buildPath = "out/${buildType}";
  libExecPath = "$out/libexec/${packageName}";

  base = rec {
    name = "${packageName}-${version}";
    inherit (upstream-info) version;
    inherit packageName buildType buildPath;

    src = upstream-info.main;

    unpackCmd = ''
      tar xf "$src" \
        --anchored \
        --no-wildcards-match-slash \
        --exclude='*/tools/gyp'
    '';

    buildInputs = defaultDependencies ++ [
      which
      python perl pkgconfig
      nspr nss systemd
      utillinux alsaLib
      bison gperf kerberos
      glib gtk dbus_glib
      libXScrnSaver libXcursor libXtst mesa
      pciutils protobuf speechd libXdamage
      pythonPackages.gyp pythonPackages.ply pythonPackages.jinja2
    ] ++ optional gnomeKeyringSupport libgnome_keyring3
      ++ optionals gnomeSupport [ gnome.GConf libgcrypt ]
      ++ optional enableSELinux libselinux
      ++ optionals cupsSupport [ libgcrypt cups ]
      ++ optional pulseSupport libpulseaudio;

    patches = [
      ./patches/widevine.patch
      ./patches/glibc-2.24.patch
      (if versionOlder version "52.0.0.0"
       then ./patches/nix_plugin_paths_50.patch
       else ./patches/nix_plugin_paths_52.patch)
    ];

    postPatch = ''
      # We want to be able to specify where the sandbox is via CHROME_DEVEL_SANDBOX
      substituteInPlace sandbox/linux/suid/client/setuid_sandbox_host.cc \
        --replace \
          'return sandbox_binary;' \
          'return base::FilePath(GetDevelSandboxPath());'

      sed -i -r \
        -e 's/-f(stack-protector)(-all)?/-fno-\1/' \
        -e 's|/bin/echo|echo|' \
        -e "/python_arch/s/: *'[^']*'/: '""'/" \
        build/common.gypi chrome/chrome_tests.gypi

      sed -i -e '/lib_loader.*Load/s!"\(libudev\.so\)!"${systemd.lib}/lib/\1!' \
        device/udev_linux/udev?_loader.cc

      sed -i -e '/libpci_loader.*Load/s!"\(libpci\.so\)!"${pciutils}/lib/\1!' \
        gpu/config/gpu_info_collector_linux.cc

      sed -i -re 's/([^:])\<(isnan *\()/\1std::\2/g' \
        chrome/browser/ui/webui/engagement/site_engagement_ui.cc
    '' + optionalString (versionAtLeast version "52.0.0.0") ''
      sed -i -re 's/([^:])\<(isnan *\()/\1std::\2/g' \
        third_party/pdfium/xfa/fxbarcode/utils.h
    '';

    gypFlags = mkGypFlags (gypFlagsUseSystemLibs // {
      linux_use_bundled_binutils = false;
      linux_use_bundled_gold = false;
      linux_use_gold_flags = true;

      proprietary_codecs = false;
      use_sysroot = false;
      use_gnome_keyring = gnomeKeyringSupport;
      use_gconf = gnomeSupport;
      use_gio = gnomeSupport;
      use_pulseaudio = pulseSupport;
      linux_link_pulseaudio = pulseSupport;
      disable_nacl = !enableNaCl;
      enable_hotwording = enableHotwording;
      selinux = enableSELinux;
      use_cups = cupsSupport;
    } // {
      werror = "";
      clang = false;
      enable_hidpi = hiDPISupport;

      # Google API keys, see:
      #   http://www.chromium.org/developers/how-tos/api-keys
      # Note: These are for NixOS/nixpkgs use ONLY. For your own distribution,
      # please get your own set of keys.
      google_api_key = "AIzaSyDGi15Zwl11UNe6Y-5XW_upsfyw31qwZPI";
      google_default_client_id = "404761575300.apps.googleusercontent.com";
      google_default_client_secret = "9rIFQjfnkykEmqb6FfjJQD1D";
    } // optionalAttrs proprietaryCodecs {
      # enable support for the H.264 codec
      proprietary_codecs = true;
      enable_hangout_services_extension = true;
      ffmpeg_branding = "Chrome";
    } // optionalAttrs (stdenv.system == "x86_64-linux") {
      target_arch = "x64";
      python_arch = "x86-64";
    } // optionalAttrs (stdenv.system == "i686-linux") {
      target_arch = "ia32";
      python_arch = "ia32";
    } // (extraAttrs.gypFlags or {}));

    configurePhase = ''
      echo "Precompiling .py files to prevent race conditions..." >&2
      python -m compileall -q -f . > /dev/null 2>&1 || : # ignore errors

      # This is to ensure expansion of $out.
      libExecPath="${libExecPath}"
      python build/linux/unbundle/replace_gyp_files.py ${gypFlags}
      python build/gyp_chromium -f ninja --depth . ${gypFlags}
    '';

    buildPhase = let
      buildCommand = target: ''
        "${ninja}/bin/ninja" -C "${buildPath}"  \
          -j$NIX_BUILD_CORES -l$NIX_BUILD_CORES \
          "${target}"
      '' + optionalString (target == "mksnapshot" || target == "chrome") ''
        paxmark m "${buildPath}/${target}"
      '';
      targets = extraAttrs.buildTargets or [];
      commands = map buildCommand targets;
    in concatStringsSep "\n" commands;
  };

# Remove some extraAttrs we supplied to the base attributes already.
in stdenv.mkDerivation (base // removeAttrs extraAttrs [
  "name" "gypFlags" "buildTargets"
])
