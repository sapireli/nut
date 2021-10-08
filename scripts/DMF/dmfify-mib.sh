#!/bin/bash

# This wrapper around Python scripts uses them to generate XML DMF files
# from existing NUT *-mib.c sources with legacy mapping structures.
# It expects to be located in (executed from) $NUT_SOURCEDIR/scripts/DMF
#
#   Copyright (C) 2016 Michal Vyskocil <MichalVyskocil@eaton.com>
#   Copyright (C) 2016 - 2021 Jim Klimov <EvgenyKlimov@eaton.com>
#

# A bashism, important for us here
set -o pipefail

# Strings must verbatim match the XSD (no trailing slash etc.)
XSD_DMFSNMP_VERSION='1.0.0'
XSD_DMFSNMP_XMLNS='http://www.networkupstools.org/dmf/snmp/snmp-ups'

# Where to look for python scripts - same dir as this shell script
_SCRIPT_DIR="`cd $(dirname "$0") && pwd`" || \
    _SCRIPT_DIR="./" # Fallback can fail

if [ -n "${PYTHON-}" ] ; then
    # May be a name/path of binary, or one with args - check both
    (command -v "$PYTHON") \
    || $PYTHON -c "import re,glob,codecs" \
    || {
        echo "----------------------------------------------------------------------"
        echo "WARNING: Caller-specified PYTHON='$PYTHON' is not available."
        echo "----------------------------------------------------------------------"
        # Do not die just here, we may not need the interpreter
    }
else
    PYTHON=""
    for P in python python3 python2.7 python2 ; do
        if (command -v "$P" >/dev/null) && $P -c "import re,glob,codecs" ; then
            PYTHON="$P"
            break
        fi
    done
fi

# TODO: The PYTHON and CC variables currently assume pathnames (no args)
# NOTE: Here unquoted(!) `command -v $PYTHON` allows to expand e.g. a
# "/usr/bin/env python" value into a real path; ignoring args to python
# itself (if any).
[ -n "${PYTHON}" ] && PYTHON="`command -v $PYTHON | tail -1`" && [ -x "$PYTHON" ] \
|| { echo "ERROR: Can not find Python 2.7+: '$PYTHON'" >&2; exit 2; }

# The pycparser uses GCC-compatible flags
[ -n "${CC-}" ] || CC="`which gcc`"
CC_ENV=""
if [ -n "${CC-}" ] ; then
    case "$CC" in
        *" "*|*\t*) # args inside? prefixed envvars?
            STAGE=env
            for TOKEN in $CC ; do
                case "$TOKEN" in
                    *=*)
                        case "$STAGE" in
                            env) CC_ENV="$CC_ENV $TOKEN" ;;
                            arg) CFLAGS="$CFLAGS $TOKEN" ;;
                        esac ;;
                    *)
                        case "$STAGE" in
                            env) STAGE=bin ; CC="$TOKEN" ;;
                            bin) STAGE=arg ; CFLAGS="$CFLAGS $TOKEN" ;;
                            arg) CFLAGS="$CFLAGS $TOKEN" ;;
                        esac ;;
                esac
            done
            ;;
    esac
    case "$CC" in
        /*) ;;
        *)  CC="`which "$CC"`" ;;
    esac
fi
[ -n "${CC}" ] && [ -x "$CC" ] || { echo "ERROR: Can not find (G)CC: '$CC'" >&2; exit 2; }
export CC CFLAGS CC_ENV

[ -n "${CPP-}" ] || CPP="`which cpp`"
CPP_ENV=""
if [ -n "${CPP-}" ] ; then
    case "$CPP" in
        *" "*|*\t*) # args inside? prefixed envvars?
            STAGE=env
            for TOKEN in $CPP ; do
                case "$TOKEN" in
                    *=*)
                        case "$STAGE" in
                            env) CPP_ENV="$CPP_ENV $TOKEN" ;;
                            arg) CPPFLAGS="$CPPFLAGS $TOKEN" ;;
                        esac ;;
                    *)
                        case "$STAGE" in
                            env) STAGE=bin ; CPP="$TOKEN" ;;
                            bin) STAGE=arg ; CPPFLAGS="$CPPFLAGS $TOKEN" ;;
                            arg) CPPFLAGS="$CPPFLAGS $TOKEN" ;;
                        esac ;;
                esac
            done
            ;;
    esac
    case "$CPP" in
        /*) ;;
        *)  CPP="`which "$CPP"`" ;;
    esac
fi
[ -n "${CPP}" ] && [ -x "$CPP" ] || { echo "ERROR: Can not find a C preprocessor: '$CPP'" >&2; exit 2; }
export CPP CPPFLAGS CPP_ENV

if [ "$1" == "--skip-sanity-check" ]; then
    shift 1
else
    # Here we only check basic prerequisites (a module provided with Python 2.7
    # and an extra module that end-user is expected to pre-install per README).
    # Other included modules will be checked when scripts are executed.
    echo "INFO: Validating some basics about your Python installation" >&2
    for PYMOD in argparse pycparser json; do
        "${PYTHON}" -c "import $PYMOD; print ($PYMOD);" || \
            { echo "ERROR: Can not use Python module '$PYMOD'" >&2; exit 2; }
    done

    eval $CPP_ENV "$CPP" $CPPFLAGS --help > /dev/null || { echo "ERROR: Can not find a C preprocessor: '$CPP'" >&2; exit 2; }
    eval $CC_ENV  "$CC"  $CFLAGS   --help > /dev/null || { echo "ERROR: Can not find a C compiler: '$CC'" >&2; exit 2; }

    if [ "$1" = "--sanity-check" ]; then
        # We are alive by now, so checks above have succeeded
        exit 0
    fi
fi

dmfify_c_file() {
    # One reqiured argument: path to a `*-mib.c` filename
    # Optional second one names the output file (and temporary files)
    local cmib="$1"
    local mib="$2"
    if [ -z "${mib}" ] ; then
        mib="$(basename "${cmib}" .c)"
    else
        # Note/FIXME: dirname is dropped, files land into current dir
        # as prepared by Makefile
        mib="$(basename "${mib}" .dmf)"
    fi

    [ -n "${cmib}" ] && [ -s "${cmib}" ] || \
        { echo "ERROR: dmfify_c_file() can not process argument '${cmib}'!" >&2
          return 2; }

    echo "INFO: Parsing '${cmib}'; do not worry if 'missing setvar' warnings pop up..." >&2

    # Code below assumes that the *.py.in only template the shebang line
    JNAME=""
    for F in "${_SCRIPT_DIR}"/jsonify-mib.py.in "${_SCRIPT_DIR}"/jsonify-mib.py ; do
        [ -s "$F" ] && JNAME="$F" && break
    done
    XNAME=""
    for F in "${_SCRIPT_DIR}"/xmlify-mib.py.in "${_SCRIPT_DIR}"/xmlify-mib.py ; do
        [ -s "$F" ] && XNAME="$F" && break
    done
    ( "${PYTHON}" "${JNAME}" --test "${cmib}" > "${mib}.json.tmp" && \
      "${PYTHON}" "${XNAME}" < "${mib}.json.tmp" > "${mib}.dmf.tmp" ) \
    && [ -s "${mib}.dmf.tmp" ] \
    || { ERRCODE=$?
        echo "ERROR: Could not parse '${cmib}' into '${mib}.dmf'" >&2
        echo "       You can inspect a copy of the intermediate result in '${mib}.json.tmp', '${mib}.dmf.tmp' and '${mib}_TEST.c'" >&2
        return $ERRCODE; }

    sed 's,^<nut>,\<nut version="'"${XSD_DMFSNMP_VERSION}"'" xmlns="'"${XSD_DMFSNMP_XMLNS}"'"\>,' < "${mib}.dmf.tmp" > "${mib}.dmf" \
    || { ERRCODE=$?
        echo "ERROR: Could not fix headers of '${mib}.dmf'" >&2
        echo "       You can inspect a copy of the intermediate result in '${mib}.json.tmp', '${mib}.dmf.tmp' and '${mib}_TEST.c'" >&2
        return $ERRCODE; }

#    mv -f "${mib}.dmf.tmp" "${mib}.dmf" \
#    && rm -f "${mib}_TEST"{.c,.exe} "${mib}.json.tmp"
}

dmfify_NUT_drivers() {
    local i=0
    # TODO? Use LEGACY_NUT_C_MIBS instead of filesystem query?
    # Got to know abs_srcdir to use it well then :)
    for cmib in ../../../drivers/*-mib.c ../../drivers/*-mib.c; do
        [ -s "${cmib}" ] || \
            { echo "ERROR: File not found or is empty: '${cmib}'" >&2; continue; }
        dmfify_c_file "${cmib}" || return
        i=$(($i+1))
    done
    [ "$i" = 0 ] && echo "ERROR: No files processed" >&2 && return 2
    echo "INFO: Processed $i files OK" >&2
    return 0
}

if [[ "$#" -gt 0 ]]; then
    echo "INFO: Got some arguments, assuming they are NUT filenames for parsing" >&2
    while [[ "$#" -gt 0 ]]; do
        case "${2-}" in
            *.dmf)
                dmfify_c_file "$1" "$2" || exit
                shift
                ;;
            *)
                dmfify_c_file "$1" || exit
                ;;
        esac
        shift
    done
else
    echo "INFO: No arguments provided, will try to parse all NUT drivers" >&2
    dmfify_NUT_drivers || exit
fi

echo "OK - All done" >&2
