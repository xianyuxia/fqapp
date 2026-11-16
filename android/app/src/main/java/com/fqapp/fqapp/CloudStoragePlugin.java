package com.fqapp.fqapp;

import android.os.Handler;
import android.os.Looper;
import org.json.*;
import java.util.*;
import java.util.concurrent.*;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.*;

/** Native protocol sessions contain no saved credentials and no reader data. */
public final class CloudStoragePlugin implements FlutterPlugin,MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private android.content.Context context;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Map<String,CloudDrive> sessions=new ConcurrentHashMap<>();
    public void onAttachedToEngine(FlutterPluginBinding binding){
        context=binding.getApplicationContext();
        channel=new MethodChannel(binding.getBinaryMessenger(),"fqapp/cloud_storage");channel.setMethodCallHandler(this);
    }
    public void onDetachedFromEngine(FlutterPluginBinding binding){channel.setMethodCallHandler(null);worker.shutdownNow();sessions.clear();}
    public void onMethodCall(MethodCall call,MethodChannel.Result result){
        worker.execute(()->{
            try {
                Object value;
                if(call.method.equals("recordServiceState")){
                    if((context.getApplicationInfo().flags&android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE)==0)throw new IllegalStateException("Debug report only");
                    Map<String,Object> args=call.arguments();JSONObject safe=new JSONObject();
                    for(String key:Arrays.asList("stage","error_type")){
                        Object item=args.get(key);if(item instanceof String&&((String)item).matches("[A-Za-z0-9_: -]{1,100}"))safe.put(key,item);
                    }
                    safe.put("time",System.currentTimeMillis());
                    try(java.io.FileOutputStream output=context.openFileOutput("cloud_service_state.json",android.content.Context.MODE_PRIVATE)){output.write(CloudDrive.bytes(safe.toString()));}
                    value=true;
                }else if(call.method.equals("recordValidation")){
                    if((context.getApplicationInfo().flags&android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE)==0)throw new IllegalStateException("Debug report only");
                    Map<String,Object> args=call.arguments();String provider=(String)args.get("provider");
                    if(!Arrays.asList("quark","tianyi","mobile139","ali","weiyun","onedrive").contains(provider))throw new IllegalArgumentException("Invalid provider");
                    JSONObject safe=new JSONObject();
                    for(String key:Arrays.asList("provider","passed","time","bidirectional_merge","delete_wins","explicit_readd","fixed_file_overwrites","readback_matches",
                        "partial_write_recovery","fixed_file_count","total_file_count","retained_existing_files","session_reopen","token_refresh","reader_records_modified","error","step")){
                        Object item=args.get(key);if(item!=null)safe.put(key,item instanceof String?((String)item).substring(0,Math.min(240,((String)item).length())):item);
                    }
                    try(java.io.FileOutputStream output=context.openFileOutput("cloud_validation_"+provider+".json",android.content.Context.MODE_PRIVATE)){output.write(CloudDrive.bytes(safe.toString()));}
                    value=true;
                }else if(call.method.equals("open")){
                    String provider=call.argument("provider"),credential=call.argument("password");
                    CloudDrive drive;
                    if("quark".equals(provider))drive=new QuarkCloudDrive(credential);
                    else if("tianyi".equals(provider))drive=new TianyiCloudDrive(credential);
                    else if("mobile139".equals(provider))drive=new MobileCloudDrive(credential);
                    else throw new IllegalArgumentException("Unsupported cloud provider");
                    drive.authenticate(Boolean.TRUE.equals(call.argument("forceRefresh")));
                    String id=UUID.randomUUID().toString();sessions.put(id,drive);
                    Map<String,Object> data=new HashMap<>();data.put("session",id);data.put("credentials",drive.credentials.toString());value=data;
                }else{
                    String id=call.argument("session");CloudDrive drive=sessions.get(id);
                    if(call.method.equals("close")){sessions.remove(id);value=null;}
                    else {
                        if(drive==null)throw new IllegalStateException("Cloud session closed");
                        switch(call.method){
                            case "folders":value=CloudFolderBrowser.folders(drive,call.argument("parent"));break;
                            case "createFolder":value=CloudFolderBrowser.create(drive,call.argument("parent"),call.argument("name"));break;
                            case "selectFolder":{
                                String folder=call.argument("folderId");
                                if(folder==null||folder.isEmpty()||folder.length()>512)throw new IllegalArgumentException("Invalid folder");
                                drive.directory=folder;drive.entries();value=null;break;
                            }
                            case "prepare":value=drive.prepare(call.argument("folder"));break;
                            case "list":{
                                List<String> names=new ArrayList<>();JSONArray entries=drive.entries();
                                for(int i=0;i<entries.length();i++){
                                    String name=entries.getJSONObject(i).optString("name");names.add(name);
                                }value=names;break;
                            }
                            case "read":{String name=call.argument("name");CloudDrive.requireSlot(name);value=drive.read(name);break;}
                            case "write":{
                                String name=call.argument("name");byte[] bytes=call.argument("bytes");CloudDrive.requireSlot(name);
                                if(bytes==null||bytes.length>CloudDrive.MAX)throw new IllegalArgumentException("Snapshot too large");
                                drive.write(name,bytes);value=null;break;
                            }
                            default:throw new IllegalArgumentException("Unsupported cloud operation");
                        }
                    }
                }
                final Object response=value;main.post(()->result.success(response));
            }catch(Exception error){
                String safe=CloudNet.safeError(error);main.post(()->result.error("cloud_storage",safe,null));
            }
        });
    }
}
