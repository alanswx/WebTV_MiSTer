#!/usr/bin/env python3
"""Refresh the root certificates built into webtv_modem.py from Mozilla's bundle.

usage: update_ca.py [cacert.pem]     (default: download https://curl.se/ca/cacert.pem)
"""
import base64, os, re, ssl, sys, urllib.request, zlib

here = os.path.dirname(os.path.abspath(__file__))
pem = open(sys.argv[1]).read() if len(sys.argv) > 1 else urllib.request.urlopen('https://curl.se/ca/cacert.pem').read().decode()
certs = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pem, re.S)
date = (re.search(r'Certificate data from Mozilla as of: (.*)', pem) or [None, 'unknown date'])[1].strip()
blob = base64.b64encode(zlib.compress(b''.join(ssl.PEM_cert_to_DER_cert(c) for c in certs), 9)).decode()
lines = '\n'.join(blob[i:i + 100] for i in range(0, len(blob), 100))
path = os.path.join(here, 'webtv_modem.py')
src = open(path).read()
src, n = re.subn(r"(# Mozilla root certificates as of: ).*\nCA_ROOTS = '''\n.*?\n'''",
                 lambda m: f"{m.group(1)}{date}, {len(certs)} roots\nCA_ROOTS = '''\n{lines}\n'''", src, flags=re.S)
if n != 1:
    sys.exit('CA_ROOTS block not found')
open(path, 'w').write(src)
print(f'{len(certs)} roots ({date}), {len(blob)} bytes')
