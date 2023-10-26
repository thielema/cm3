# ToDo: add support for Trestle (depends on X11 and OpenGL)
{ lib
, stdenv
, fetchurl
, zlib
, cmake
, python3
, gcc
}:

stdenv.mkDerivation rec {
  pname = "cm3";
  version = "5.11.4";

  src =
    if stdenv.hostPlatform.system == "i686-linux" then fetchurl {
      url = "https://github.com/modula3/cm3/releases/download/d5.11.4/cm3-dist-I386_LINUX-d5.11.4.tar.xz";
      sha256 = "sha256-+KIq3GLkXTVeFtHCOrdC0nslBxwLjQWvLCkoXtzHr2k=";
    } else fetchurl {
      url = "https://github.com/modula3/cm3/releases/download/d5.11.4/cm3-dist-AMD64_LINUX-d5.11.4.tar.xz";
      sha256 = "sha256-Cbmkg5uSQOLYm0fL7axssMBPbOswcyfyPbd/rqoav8o=";
    };

  buildInputs = [ cmake python3 gcc ];

  dontConfigure = true;

  installPhase = ''
mkdir build
cd build
python ../scripts/concierge.py install --prefix $out PATH=$out/bin:$PATH
'';

  meta = {
    description = "CM3 - Critical Mass Modula-3 compiler";
    homepage = "https://modula3.org/";
    license = lib.licenses.mit;
    platforms = [ "i686-linux" "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  };
}
