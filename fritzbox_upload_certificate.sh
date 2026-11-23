#!/bin/bash

# Copyright (C) 2020 Franz Schwartau (Updated with PBKDF2 & Python support)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# default parameters from environment
baseurl="${FRITZBOX_BASEURL:-}"
certpath="${FRITZBOX_CERTPATH:-}"
debug="${FRITZBOX_DEBUG:-}"
fullchain="${FRITZBOX_FULLCHAIN:-}"
password="${FRITZBOX_PASSWORD:-}"
privkey="${FRITZBOX_PRIVKEY:-}"
username="${FRITZBOX_USERNAME:-}"

tmp_dir="${TMPDIR:-/tmp}"

CURL_CMD="curl"
OPENSSL_CMD="openssl"
PYTHON_CMD="python3"

SUCCESS_MESSAGES="^ *(Das SSL-Zertifikat wurde erfolgreich importiert|Import of the SSL certificate was successful|El certificado SSL se ha importado correctamente|Le certificat SSL a été importé|Il certificato SSL è stato importato( correttamente)?|Import certyfikatu SSL zosta pomylnie zakoczony|Het SSL-certificaat werd ge.*mporteerd)\.$"

function usage {
  echo "Usage: $0 [-b baseurl] [-u username] [-p password] [[-c certpath]|[-f fullchain] [-k privkey]]" >&2
  exit 64
}

function error {
  local msg=$1

  [ "${msg}" ] && echo "${msg}" >&2
  exit 1
}

exit_code=0

for cmd in ${CURL_CMD} ${OPENSSL_CMD} ${PYTHON_CMD}; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Please install ${cmd}" >&2
    exit_code=1
  fi
done

[ ${exit_code} -ne 0 ] && exit ${exit_code}

while getopts ":b:c:df:k:p:u:h" opt; do
  case ${opt} in
    b)
      baseurl=$OPTARG
      ;;
    c)
      certpath=$OPTARG
      ;;
    d)
      debug="true"
      ;;
    f)
      fullchain=$OPTARG
      ;;
    k)
      privkey=$OPTARG
      ;;
    p)
      password=$OPTARG
      ;;
    u)
      username=$OPTARG
      ;;
    h)
      usage
      ;;
    \?)
      echo "Invalid option: $OPTARG" >&2
      echo >&2
      usage
      ;;
    :)
      echo "Invalid option: $OPTARG requires an argument" >&2
      echo >&2
      usage
      ;;
  esac
done

shift $((OPTIND - 1))

exit_code=0

for var in baseurl username password; do
  if [ -z "${!var}" ]; then
    echo "Please set ${var}" >&2
    exit_code=1
  fi
done

# certpath XOR (fullchain AND privkey) must be set
using_certpath="false"
[ -n "${certpath}" ] && using_certpath="true"

if [[ (-z "${certpath}" && (-z "${fullchain}" || -z "${privkey}")) || (-n "${certpath}" && (-n "${fullchain}" || -n "${privkey}")) ]]; then
  echo "Either certpath or fullchain and privkey have to be set." >&2
  exit_code=1
fi

[ ${exit_code} -ne 0 ] && exit ${exit_code}

# strip trailing slash
baseurl="${baseurl%/}"

# if no schema was given, default to https
if [[ "${baseurl}" != *://* ]]; then
  baseurl="https://${baseurl}"
fi

if [ "${using_certpath}" = "true" ]; then
  fullchain="${certpath}/fullchain.pem"
  privkey="${certpath}/privkey.pem"
fi

if [ ! -r "${fullchain}" ] || [ ! -r "${privkey}" ]; then
  if [ "${using_certpath}" = "true" ]; then
    error "Certpath ${certpath} must contain fullchain.pem and privkey.pem"
  else
    error "fullchain (${fullchain}) and privkey (${privkey}) must both be readable files"
  fi
fi

if [ -n "${debug}" ]; then
  debug_output="$(mktemp "${tmp_dir}/fritzbox_debug.XXXXXX")"

  curl_opts=(--verbose --silent --stderr -)

  function process_curl_output {
    grep -v '^[*{}]' | sed -e '1i\
' | tee -a "${debug_output}"
  }

  echo "Debug output will be written to ${debug_output}"
else
  curl_opts=(--silent --show-error)

  function process_curl_output {
    cat
  }
fi

request_file="$(mktemp "${tmp_dir}/request.XXXXXX")"

cleanup() {
  rm -f "${request_file}"

  if [ -n "${sid:-}" ] && [ "${sid}" != "0000000000000000" ]; then
    ${CURL_CMD} "${curl_opts[@]}" "${baseurl}/login_sid.lua?logout=1&sid=${sid}" | process_curl_output >/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

# login to the box and get a valid SID (supports both v1 MD5 and v2 PBKDF2)
challenge="$(${CURL_CMD} "${curl_opts[@]}" "${baseurl}/login_sid.lua?version=2" | process_curl_output | sed -ne 's/^.*<Challenge>\([^<]*\)<\/Challenge>.*$/\1/p')"
if [ -z "${challenge}" ]; then
  error "Invalid challenge received."
fi

if [[ "${challenge}" == 2\$* ]]; then
  # PBKDF2 (version 2)
  response="$(${PYTHON_CMD} -c '
import sys, hashlib
challenge = sys.argv[1]
password = sys.argv[2].encode("utf-8")
parts = challenge.split("$")
iter1 = int(parts[1])
salt1 = bytes.fromhex(parts[2])
iter2 = int(parts[3])
salt2 = bytes.fromhex(parts[4])
hash1 = hashlib.pbkdf2_hmac("sha256", password, salt1, iter1)
hash2 = hashlib.pbkdf2_hmac("sha256", hash1, salt2, iter2)
print(f"{parts[4]}${hash2.hex()}")
' "${challenge}" "${password}")"
else
  # Legacy MD5 (version 1 via Python UTF-16LE)
  md5hash="$(${PYTHON_CMD} -c '
import sys, hashlib
data = f"{sys.argv[1]}-{sys.argv[2]}".encode("utf-16le")
print(hashlib.md5(data).hexdigest())
' "${challenge}" "${password}")"
  response="${challenge}-${md5hash}"
fi

sid="$(${CURL_CMD} "${curl_opts[@]}" --request POST --data-urlencode "username=${username}" --data-urlencode "response=${response}" "${baseurl}/login_sid.lua?version=2" | process_curl_output | sed -ne 's/^.*<SID>\([0-9a-f][0-9a-f]*\)<\/SID>.*$/\1/p')"
if [ -z "${sid}" ] || [ "${sid}" = "0000000000000000" ]; then
  error "Login failed."
fi

certbundle=$(cat "${fullchain}" "${privkey}" | grep -v '^$')

# generate our upload request
boundary="---------------------------$(${OPENSSL_CMD} rand -hex 20)"

cat <<EOD >>"${request_file}"
--${boundary}
Content-Disposition: form-data; name="sid"

${sid}
--${boundary}
Content-Disposition: form-data; name="BoxCertImportFile"; filename="BoxCert.pem"
Content-Type: application/octet-stream

${certbundle}
--${boundary}--
EOD

# upload the certificate to the box
result="$(${CURL_CMD} "${curl_opts[@]}" --request POST "${baseurl}/cgi-bin/firmwarecfg" --header "Content-type: multipart/form-data; boundary=${boundary}" --data-binary "@${request_file}" | process_curl_output | grep -E "${SUCCESS_MESSAGES}")"

if [ -z "${result}" ]; then
  error "Could not import certificate. Maybe an unsupported key type was used. Older Fritz!OS versions support RSA keys only."
else
  echo "${result}" | sed -e 's/^[[:space:]]*//'
fi

