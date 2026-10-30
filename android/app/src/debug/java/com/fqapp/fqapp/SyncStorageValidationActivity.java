package com.fqapp.fqapp;
import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Debug-only harness: fixed loopback ports and disposable local test services.
 * Does not read or change reader data, settings, cloud tokens, or user shares. */
public final class SyncStorageValidationActivity extends Activity {
    public void onCreate(Bundle state){
        super.onCreate(state);TextView label=new TextView(this);label.setText("正在验证本机 FTP / FTPS / SMB…");setContentView(label);
        new Thread(()->{
            JSONObject report=new JSONObject();
            for(String provider:new String[]{"ftp","smb","ftps"}){
                String phase="prepare";
                try{
                    Map<String,Object> args=new HashMap<>();args.put("provider",provider);
                    args.put("username","probe-only");args.put("password","probe-only");
                    args.put("endpoint",provider.equals("smb")?"smb://127.0.0.1:18445/sync/fqappx-sync-validation/":
                        provider+"://127.0.0.1:"+(provider.equals("ftps")?18212:18211)+"/fqappx-sync-validation/");
                    if(provider.equals("ftps")){
                        try{SyncStoragePlugin.ftp("prepare",args,"");report.put("ftps_untrusted_certificate_rejected",false);}
                        catch(Exception expected){report.put("ftps_untrusted_certificate_rejected",true);}
                        // Pin only this disposable local service's public test
                        // certificate. Do not change Android's trusted CA store.
                        java.security.cert.CertificateFactory certs=java.security.cert.CertificateFactory.getInstance("X.509");
                        java.security.KeyStore anchors=java.security.KeyStore.getInstance(java.security.KeyStore.getDefaultType());anchors.load(null);
                        try(java.io.FileInputStream input=openFileInput("sync_test_ca.pem")){
                            anchors.setCertificateEntry("loopback-test",certs.generateCertificate(input));
                        }
                        javax.net.ssl.TrustManagerFactory factory=javax.net.ssl.TrustManagerFactory.getInstance(javax.net.ssl.TrustManagerFactory.getDefaultAlgorithm());factory.init(anchors);
                        for(javax.net.ssl.TrustManager manager:factory.getTrustManagers())if(manager instanceof javax.net.ssl.X509TrustManager)args.put("testTrust",manager);
                        args.put("endpoint","ftps://localhost:18212/fqappx-sync-validation/");
                    }
                    invoke(provider,"prepare",args,"");
                    for(int i=1;i<=8;i++){
                        String name="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee."+(i%2==0?"a":"b")+".json";
                        byte[] bytes=("{\"test\":"+i+"}").getBytes(StandardCharsets.UTF_8);
                        args.put("bytes",bytes);invoke(provider,"write",args,name);
                        phase="readback";
                        if(!Arrays.equals(bytes,(byte[])invoke(provider,"read",args,name)))throw new Exception();
                    }
                    List<?> names=(List<?>)invoke(provider,"list",args,"");
                    report.put(provider+"_overwrite_readback",names.size()==2);
                }catch(Exception failure){try{
                    report.put(provider+"_overwrite_readback",false);
                    report.put(provider+"_failure_phase",phase);
                    report.put(provider+"_failure_class",failure.getClass().getSimpleName());
                    // This harness has ONLY fixed dummy credentials and loopback
                    // endpoints, so its diagnostic message contains no user data.
                    report.put(provider+"_failure_detail",failure.getMessage());
                }catch(Exception ignored2){}}
            }
            try(java.io.FileOutputStream out=openFileOutput("sync_storage_validation.json",MODE_PRIVATE)){
                out.write(report.toString().getBytes(StandardCharsets.UTF_8));
            }catch(Exception ignored){}
            runOnUiThread(()->label.setText(report.toString()));
        },"sync-storage-validation").start();
    }
    private static Object invoke(String provider,String action,Map<String,Object> args,String name)throws Exception{
        return provider.equals("smb")?SyncStoragePlugin.smb(action,args,name):
            SyncStoragePlugin.ftp(action,args,name,(javax.net.ssl.X509TrustManager)args.get("testTrust"));
    }
}
