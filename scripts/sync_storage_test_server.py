"""Loopback-only disposable FTP/FTPS/SMB services for the Android debug harness.
Requires pyftpdlib, pyopenssl, impacket in an isolated test environment.
No user cloud accounts or reader data are involved.
"""
from pathlib import Path
import argparse, threading, json, time
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer
from impacket.smbserver import SimpleSMBServer
from impacket import ntlm
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from datetime import datetime, timedelta, timezone
from ipaddress import ip_address

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,required=True)
    root=parser.parse_args().root.resolve();root.mkdir(parents=True,exist_ok=True)
    ftp_root=root/'ftp';smb_root=root/'smb'
    ftp_root.mkdir(exist_ok=True);smb_root.mkdir(exist_ok=True)
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'localhost')])
    now=datetime.now(timezone.utc)
    cert=(x509.CertificateBuilder().subject_name(name).issuer_name(name)
          .public_key(key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now-timedelta(minutes=1)).not_valid_after(now+timedelta(days=1))
          .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost'),x509.IPAddress(ip_address('127.0.0.1'))]),critical=False)
          .sign(key,hashes.SHA256()))
    public=cert.public_bytes(serialization.Encoding.PEM)
    cert_file=root/'test-cert.pem';cert_file.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.TraditionalOpenSSL,serialization.NoEncryption())+public)
    (root/'test-public-cert.pem').write_bytes(public)
    class Plain(FTPHandler):pass
    class Secure(TLS_FTPHandler):pass
    auth=DummyAuthorizer();auth.add_user('probe-only','probe-only',str(ftp_root),perm='elradfmwMT')
    for cls in (Plain,Secure):
        cls.authorizer=auth;cls.passive_ports=range(18310,18320)
    Secure.certfile=str(cert_file);Secure.tls_control_required=True;Secure.tls_data_required=True
    # Each pyftpdlib server has its own event loop, avoiding shared socket maps.
    from pyftpdlib.ioloop import IOLoop
    ftp=FTPServer(('127.0.0.1',18211),Plain,ioloop=IOLoop())
    ftps=FTPServer(('127.0.0.1',18212),Secure,ioloop=IOLoop())
    smb=SimpleSMBServer(listenAddress='127.0.0.1',listenPort=18445)
    smb.addShare('sync',str(smb_root),'Disposable sync validation')
    smb.setSMB2Support(True)
    smb.addCredential('probe-only',0,ntlm.compute_lmhash('probe-only').hex(),ntlm.compute_nthash('probe-only').hex())
    smb.setLogFile(str(root/'smb-server.log'))
    for action in [ftp.serve_forever,ftps.serve_forever,smb.start]:
        threading.Thread(target=action,daemon=True).start()
    print(json.dumps({'loopback_only':True,'ftp':18211,'ftps':18212,'smb':18445}),flush=True)
    try:
        while not (root/'stop').exists():time.sleep(1)
    except KeyboardInterrupt:pass
    finally:ftp.close_all();ftps.close_all();smb.stop()

if __name__=='__main__':main()
