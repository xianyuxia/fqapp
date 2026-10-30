package com.wulalalala.fqappx.research;

import android.app.Activity;
import android.os.Bundle;
import android.util.Base64;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/** Disposable native WebDAV check. Credentials enter via app-private stdin file only. */
public final class WebDavProbeActivity extends Activity {
    private final JSONObject report=new JSONObject();
    private final JSONArray steps=new JSONArray();
    private final Map<String,String> auth=new LinkedHashMap<>();
    private TextView status;
    private String directory,file;
    private boolean created=false;
    private static final String ENDPOINT="https://dav.jianguoyun.com/dav/";
    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        status=new TextView(this);status.setTextSize(17);status.setPadding(25,45,25,25);
        status.setText("通用 WebDAV · 坚果云\n只读写新建的 CloudProbe 测试目录。\n正在验证……");setContentView(status);
        new Thread(this::runProbe,"WebDAV-isolated-probe").start();
    }
    private void put(String key,Object value){try{report.put(key,value);}catch(Exception ignored){}}
    private void save(){
        try(FileOutputStream out=openFileOutput("webdav-report.json",MODE_PRIVATE)){
            out.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
        }catch(Exception ignored){}
    }
    private Net.Response request(String label,String method,String url,Map<String,String> extra,byte[] body)throws Exception{
        if(directory==null||!(url.equals(directory)||url.equals(file)))throw new IOException("Outside own test directory");
        Map<String,String> h=new LinkedHashMap<>(auth);h.putAll(extra);
        Net.Response r=Net.exactRequest(method,url,h,body,65536);
        JSONObject step=new JSONObject();step.put("step",label);step.put("method",method);step.put("status",r.status);steps.put(step);save();
        return r;
    }
    private Net.Response request(String label,String method,String url)throws Exception{return request(label,method,url,Collections.emptyMap(),null);}
    private void require(boolean condition,String stage)throws Exception{if(!condition)throw new IOException(stage);}
    private static String header(Net.Response r,String key){
        for(Map.Entry<String,List<String>> e:r.headers.entrySet())if(key.equalsIgnoreCase(e.getKey())&&!e.getValue().isEmpty())return e.getValue().get(0);
        return "";
    }
    private void runProbe(){
        File input=new File(getFilesDir(),"webdav-probe-input.json");
        put("package",getPackageName());put("provider","Nutstore via generic WebDAV");put("credentials_exported",false);
        put("account_identity_recorded",false);put("started_at_ms",System.currentTimeMillis());put("steps",steps);put("state","running");save();
        try{
            JSONObject config;
            try(FileInputStream in=new FileInputStream(input)){
                ByteArrayOutputStream data=new ByteArrayOutputStream();byte[] buf=new byte[1024];int n;
                while((n=in.read(buf))!=-1){if(data.size()+n>4096)throw new IOException("Credential input too large");data.write(buf,0,n);}
                config=new JSONObject(new String(data.toByteArray(),StandardCharsets.UTF_8));
            }finally{put("credential_input_deleted",!input.exists()||input.delete());}
            require(report.optBoolean("credential_input_deleted"),"Private credential input deletion failed");
            require(ENDPOINT.equals(config.getString("endpoint")),"Unapproved endpoint");
            String account=config.getString("account"),password=config.getString("password");
            auth.put("Authorization","Basic "+Base64.encodeToString((account+":"+password).getBytes(StandardCharsets.UTF_8),Base64.NO_WRAP));
            config=null;account=null;password=null;
            String id=UUID.randomUUID().toString().substring(0,8);
            String name="CloudProbe-WebDAV-"+id;directory=ENDPOINT+name+"/";file=directory+"reading-progress.json";
            put("test_directory",name);put("test_file","reading-progress.json");
            Net.Response mkdir=request("create_own_directory","MKCOL",directory);
            require(mkdir.status==201,"Create directory did not return 201");created=true;put("create_directory",true);
            byte[] first=("{\"probe\":\""+id+"\",\"chapter\":1,\"note\":\"阅读进度测试\"}\n").getBytes(StandardCharsets.UTF_8);
            byte[] second=("{\"probe\":\""+id+"\",\"chapter\":2,\"note\":\"覆盖写入验证\"}\n").getBytes(StandardCharsets.UTF_8);
            Map<String,String> json=Net.headers("Content-Type","application/json; charset=utf-8");
            Net.Response upload=request("upload","PUT",file,json,first);require(upload.status==201||upload.status==204,"Upload failed");put("upload",true);
            Net.Response download=request("download","GET",file);require(download.status==200&&Arrays.equals(first,download.body),"Download content mismatch");
            put("download",true);put("content_matches",true);put("initial_bytes",first.length);
            put("etag_present",!header(download,"ETag").isEmpty());
            Net.Response listing=request("list_own_directory","PROPFIND",directory,Net.headers("Depth","1"),null);
            boolean listed=listing.status==207&&listing.text().contains("reading-progress.json");put("list",listed);require(listed,"Own file missing from listing");
            Net.Response overwrite=request("overwrite","PUT",file,json,second);require(overwrite.status==201||overwrite.status==204,"Overwrite failed");
            Net.Response reread=request("download_overwritten","GET",file);require(reread.status==200&&Arrays.equals(second,reread.body),"Overwrite content mismatch");
            put("overwrite",true);put("overwrite_content_matches",true);put("final_bytes",second.length);
            Map<String,String> ifAbsent=new LinkedHashMap<>(json);ifAbsent.put("If-None-Match","*");
            Net.Response absent=request("reject_create_if_exists","PUT",file,ifAbsent,first);
            put("if_none_match_existing_rejected",absent.status==412);
            Map<String,String> ifStale=new LinkedHashMap<>(json);ifStale.put("If-Match","\"cloudprobe-deliberately-stale\"");
            Net.Response stale=request("reject_stale_overwrite","PUT",file,ifStale,first);
            put("if_match_stale_rejected",stale.status==412);
            Net.Response after=request("read_after_conditional_checks","GET",file);
            put("conditional_checks_preserved_content",after.status==200&&Arrays.equals(second,after.body));
            byte[] digest=MessageDigest.getInstance("SHA-256").digest(second);StringBuilder hex=new StringBuilder();for(byte b:digest)hex.append(String.format(Locale.ROOT,"%02x",b&255));put("overwrite_sha256",hex.toString());
            put("read_write_passed",true);put("state","passed");
        }catch(Exception error){put("state","failed");put("error_class",error.getClass().getSimpleName());}
        finally{
            if(created){
                try{Net.Response deleted=request("delete_own_file","DELETE",file);put("delete_file_status",deleted.status);Net.Response missing=request("confirm_own_file_absent","GET",file);put("own_test_file_absent",missing.status==404);}catch(Exception e){put("file_cleanup_error",e.getClass().getSimpleName());}
                try{Net.Response deleted=request("delete_own_empty_directory","DELETE",directory);put("delete_directory_status",deleted.status);Net.Response missing=request("confirm_own_directory_absent","PROPFIND",directory,Net.headers("Depth","0"),null);put("own_test_directory_absent",missing.status==404);}catch(Exception e){put("directory_cleanup_error",e.getClass().getSimpleName());}
            }
            auth.clear();put("credentials_kept_in_memory_only",true);put("finished_at_ms",System.currentTimeMillis());save();
            final String message=report.optBoolean("read_write_passed")?"WebDAV 上传、下载、覆盖验证通过":"WebDAV 验证未完成";
            runOnUiThread(()->status.setText("通用 WebDAV · 坚果云\n"+message+"\n测试文件清理："+report.optBoolean("own_test_file_absent")+"\n测试目录清理："+report.optBoolean("own_test_directory_absent")));
        }
    }
}
