#!/usr/bin/env python3
"""Explicitly configure vision.observe and issue a replacement DEVICE invitation.

Uses only canonical body maintenance and the frozen pairing API. Never broadens
an existing credential. Keep the retained body profile; revoke the old DEVICE
credential separately only after the new one has enrolled successfully.
"""
import argparse
import json
import os
import re
import subprocess
from datetime import datetime
from pathlib import Path

REMOTE_PROGRAM = r'''
import asyncio, json, os, ssl, sys
from dataclasses import replace
from pathlib import Path
from urllib.request import Request, HTTPSHandler, HTTPRedirectHandler, build_opener
from home_cortex.config import get_settings
from home_cortex.persistence.db import Database
from home_cortex.mutation.embodiments import EmbodimentWritingService
from home_cortex.spatial.embodiment import embodiment_as_mapping
body, action = sys.argv[1:]
root = Path('/home/jkuang/.local/share/home-cortex/client-interface')
if action == 'prepare':
    async def setup():
        db = Database(get_settings()); await db.connect()
        try:
            writer = EmbodimentWritingService(db)
            old = await writer.get(body)
            assert old.agent_id == 'agent:butler' and old.capabilities in ((), ('vision.observe',))
            if not old.capabilities: await writer.update(replace(old, capabilities=('vision.observe',), agent_id=None))
            new = await writer.get(body)
            assert new.agent_id == old.agent_id and new.capabilities == ('vision.observe',)
            profile = embodiment_as_mapping(new); profile.pop('agent_id', None)
            print(json.dumps(profile))
        finally: await db.close()
    asyncio.run(setup())
else:
    os.umask(0o077)
    output = root/'provisioning/iphone-vision-invitation.json'
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        context = ssl.create_default_context(cafile=str(root/'operator/ca.crt'))
        context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
        context.load_cert_chain(str(root/'operator/client.crt'), str(root/'operator/client.key'))
        grants = [{'embodiment_id':body,'verb':'session','capability':None},
                  {'embodiment_id':body,'verb':'receive','capability':'vision.observe'}]
        payload = {'operation':'create','embodiment_id':body,'purpose':'DEVICE','grants':grants,'expires_in_s':600}
        endpoint = 'https://192.168.68.59:8443'
        class NoRedirect(HTTPRedirectHandler):
            def redirect_request(self,*args,**kwargs): return None
        request = Request(endpoint+'/client-interface/v1/pairings',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
        with build_opener(HTTPSHandler(context=context),NoRedirect()).open(request,timeout=10) as response:
            invitation = json.load(response)
        assert set(invitation)=={'invitation_id','token','expires_at','server_endpoint','embodiment_id','purpose','grants'}
        assert invitation['purpose']=='DEVICE' and invitation['embodiment_id']==body and invitation['grants']==grants and invitation['server_endpoint']==endpoint
        with os.fdopen(fd,'w') as stream: json.dump(invitation,stream); stream.flush(); os.fsync(stream.fileno())
        print('Owner-private replacement DEVICE invitation issued; no token printed.')
    except BaseException:
        output.unlink(missing_ok=True)
        raise
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    directory = Path(__file__).resolve().parents[1]/'.local/provisioning'
    profile = directory/'iphone-embodiment.json'
    body = json.loads(profile.read_text())['id']
    if not re.fullmatch(r'embodiment:[A-Za-z0-9_-]+',body): raise SystemExit('Invalid retained phone body.')
    server = 'jkuang@192.168.68.59'
    output = directory/'iphone-vision-invitation.json'
    if not args.prepare_only and output.exists(): raise SystemExit('Remove expired/consumed invitation copies first; keep the profile.')
    # Run canonical writing service with the API container's configured DB.
    prepared = subprocess.run(['ssh','-o','BatchMode=yes',server,'docker exec -i cortex-cortex-api-1 python - '+body+' prepare'],input=REMOTE_PROGRAM,text=True,check=True,capture_output=True)
    record = json.loads(prepared.stdout)
    if record['id'] != body or record['capabilities'] != ['vision.observe']: raise SystemExit('Unexpected canonical profile.')
    profile.write_text(json.dumps(record,indent=2)+'\n'); profile.chmod(0o600)
    subprocess.run(['scp','-q',str(profile),server+':/home/jkuang/.local/share/home-cortex/client-interface/provisioning/iphone-embodiment.json'],check=True)
    print('Canonical phone profile supports only vision.observe; association retained.')
    if args.prepare_only: return
    subprocess.run(['ssh','-o','BatchMode=yes',server,'cd /home/jkuang/Workspace/home-cortex && PYTHONPATH=src .venv/bin/python - '+body+' invite'],input=REMOTE_PROGRAM,text=True,check=True)
    subprocess.run(['scp','-q',server+':/home/jkuang/.local/share/home-cortex/client-interface/provisioning/iphone-vision-invitation.json',str(output)],check=True)
    output.chmod(0o600)
    invitation=json.loads(output.read_text())
    expiry=datetime.fromisoformat(invitation['expires_at'].replace('Z','+00:00')).astimezone()
    print('AirDrop '+str(output)+' to iPhone Files.')
    print('Expires '+expiry.strftime('%Y-%m-%d %H:%M:%S %Z'))
    print('Home Cortex → gear → This iPhone → Upgrade Vision Access → Import DEVICE invitation.')

if __name__=='__main__': main()
