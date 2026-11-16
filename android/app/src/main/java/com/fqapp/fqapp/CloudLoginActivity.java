package com.fqapp.fqapp;

import android.app.Activity;
import android.content.*;
import android.net.Uri;
import android.os.*;
import android.util.Base64;
import android.webkit.*;
import android.widget.*;
import android.view.ViewGroup;
import org.json.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** Official web login and supported client handoffs. No JavaScript bridge,
 * package/signature impersonation, credential logs or system browser cookies. */
public final class CloudLoginActivity extends Activity {
    private WebView web;
    private FrameLayout content;
    private String provider, weiyunCode="", quarkPage="", lastCandidate="";
    private QuarkCloudDrive quark;
    private final Map<WebView,String> popupOrigins=new WeakHashMap<>();
    private boolean completed, pollBusy;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Runnable poll=new Runnable(){public void run(){
        if(completed)return;capture();pollRemote();handler.postDelayed(this,3000);
    }};
    @Override public void onCreate(Bundle state){
        super.onCreate(state);provider=getIntent().getStringExtra("provider");
        loginState("starting","",0);
        LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.VERTICAL);
        layout.setOnApplyWindowInsetsListener((view,insets)->{
            if(android.os.Build.VERSION.SDK_INT>=30){
                android.graphics.Insets bars=insets.getInsets(android.view.WindowInsets.Type.systemBars());
                view.setPadding(bars.left,bars.top,bars.right,bars.bottom);
            }else view.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());
            return insets;
        });
        LinearLayout controls=new LinearLayout(this);
        Button done=new Button(this);done.setText("重新检查登录状态");done.setOnClickListener(v->{capture();pollRemote();});
        if(!"weiyun".equals(provider))controls.addView(done);
        if("weiyun".equals(provider)){
            Button qq=new Button(this);qq.setText("QQ 登录");qq.setOnClickListener(v->{
                web.getSettings().setUserAgentString(mobileAgent(WebSettings.getDefaultUserAgent(this)));
                web.loadUrl("https://h5.weiyun.com/");
            });controls.addView(qq,new LinearLayout.LayoutParams(0,-2,1));
            Button authorize=new Button(this);authorize.setText("继续同步授权");authorize.setOnClickListener(v->{
                web.getSettings().setUserAgentString(mobileAgent(WebSettings.getDefaultUserAgent(this)));
                web.loadUrl("https://www.weiyun.com/authorize/token?code="+weiyunCode);
            });controls.addView(authorize,new LinearLayout.LayoutParams(0,-2,1));
            Button desktop=new Button(this);desktop.setText("扫码登录");desktop.setOnClickListener(v->{
                web.getSettings().setUserAgentString("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36");
                web.loadUrl("https://www.weiyun.com/authorize/token?code="+weiyunCode);
            });controls.addView(desktop,new LinearLayout.LayoutParams(0,-2,1));
        }
        layout.addView(controls);content=new FrameLayout(this);layout.addView(content,new LinearLayout.LayoutParams(-1,0,1));setContentView(layout);
        web=makeWeb();content.addView(web,new FrameLayout.LayoutParams(-1,-1));
        CookieManager.getInstance().setAcceptCookie(true);
        if("quark".equals(provider)){
            worker.execute(()->{try{
                quark=new QuarkCloudDrive("{}");JSONObject start=quark.beginLogin();quarkPage=start.getString("page_code");
                handler.post(()->{if(!completed)web.loadUrl(start.optString("url"));});
            }catch(Exception error){handler.post(()->toast("夸克授权入口暂不可用，请重试"));}});
        }else if("weiyun".equals(provider)){
            weiyunCode=UUID.randomUUID().toString().replace("-","").substring(0,16);
            web.loadUrl("https://www.weiyun.com/authorize/token?code="+weiyunCode);
        }else if("ali".equals(provider))web.loadUrl("https://www.alipan.com/sign/in");
        else if("tianyi".equals(provider))web.loadUrl("https://api.cloud.189.cn/open/oauth2/ssoH5.action?redirectURL=https%3A%2F%2Fh5.cloud.189.cn%2Fmain.html");
        else if("mobile139".equals(provider))web.loadUrl("https://yun.139.com/w/");
        else if("onedrive".equals(provider))beginOneDrive();
        else{finish();return;}
        handler.postDelayed(poll,1200);
    }
    private WebView makeWeb(){
        WebView view=new WebView(this);WebSettings settings=view.getSettings();
        settings.setJavaScriptEnabled(true);settings.setDomStorageEnabled(true);settings.setUseWideViewPort(true);settings.setLoadWithOverviewMode(true);
        // Android tablets omit the Mobile token. Request the phone login flow
        // for these services instead of a desktop form or scan-only entry.
        if("mobile139".equals(provider)||"ali".equals(provider)||"weiyun".equals(provider)){
            settings.setUserAgentString(mobileAgent(settings.getUserAgentString()));
        }
        settings.setAllowFileAccess(false);settings.setAllowContentAccess(false);settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSupportMultipleWindows(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(view,true);
        view.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView current,WebResourceRequest request){
                Uri uri=request.getUrl();if(captureOneDrive(uri))return true;
                if("https".equals(uri.getScheme()))return false;
                return handoff(current,uri);
            }
            @Override public boolean shouldOverrideUrlLoading(WebView current,String address){
                Uri uri=Uri.parse(address);if(captureOneDrive(uri))return true;
                return !"https".equals(uri.getScheme())&&handoff(current,uri);
            }
            @Override public void onPageStarted(WebView current,String url,android.graphics.Bitmap icon){if(!completed){loginState("loading",Uri.parse(url).getHost(),0);captureOneDrive(Uri.parse(url));}}
            @Override public void onPageFinished(WebView current,String url){if(!completed){loginState("ready",Uri.parse(url).getHost(),0);captureFrom(current);}}
            @Override public void onReceivedError(WebView current,WebResourceRequest request,WebResourceError error){
                if(request.isForMainFrame()){loginState("page_error",request.getUrl().getHost(),error.getErrorCode());toast("官方登录页加载失败，请检查网络后重试");}
            }
            @Override public WebResourceResponse shouldInterceptRequest(WebView current,WebResourceRequest request){
                if("mobile139".equals(provider)&&official(request.getUrl().getHost(),"139.com","10086.cn")){
                    for(Map.Entry<String,String> header:request.getRequestHeaders().entrySet()){
                        String value=header.getValue();
                        if("Authorization".equalsIgnoreCase(header.getKey())&&value!=null&&value.startsWith("Basic ")&&value.length()<32768){
                            verifyCandidate(value);break;
                        }
                    }
                }
                return null;
            }
        });
        view.setWebChromeClient(new WebChromeClient(){
            @Override public boolean onCreateWindow(WebView source,boolean dialog,boolean gesture,Message result){
                if(!gesture)return false;
                WebView child=makeWeb();child.getSettings().setUserAgentString(source.getSettings().getUserAgentString());
                String opener=source.getUrl()==null?null:Uri.parse(source.getUrl()).getHost();
                if(official(opener,"weiyun.com","qq.com","weixin.qq.com","quark.cn","alipan.com","aliyundrive.com"))popupOrigins.put(child,opener);
                content.addView(child,new FrameLayout.LayoutParams(-1,-1));web=child;
                ((WebView.WebViewTransport)result.obj).setWebView(child);result.sendToTarget();return true;
            }
            @Override public void onCloseWindow(WebView child){content.removeView(child);child.destroy();
                if(content.getChildCount()>0)web=(WebView)content.getChildAt(content.getChildCount()-1);
            }
        });return view;
    }
    private static String mobileAgent(String agent){
        return agent.contains("Mobile")?agent:agent.replace(" Safari/"," Mobile Safari/");
    }
    private void beginOneDrive(){
        final String agent=WebSettings.getDefaultUserAgent(this);
        worker.execute(()->{try{
            String origin="https://api.oplist.org/";
            CloudNet.Response response=CloudNet.request("GET",origin+"onedrive/requests?driver_txt=onedrive_pr&server_use=true",
                CloudNet.headers("Accept","application/json","User-Agent",agent,"Referer",origin),null,256*1024);
            if(response.status!=200)throw new java.io.IOException("Authorization HTTP "+response.status);
            String address=new JSONObject(response.text()).getString("text");Uri uri=Uri.parse(address);
            if(!"https".equals(uri.getScheme())||!official(uri.getHost(),"microsoftonline.com","live.com"))throw new java.io.IOException("Untrusted Microsoft authorization URL");
            List<String> cookies=new ArrayList<>();
            for(Map.Entry<String,List<String>> header:response.headers.entrySet())if("Set-Cookie".equalsIgnoreCase(header.getKey()))cookies.addAll(header.getValue());
            // These are public routing preferences used by the broker callback.
            cookies.add("driver_txt=onedrive_pr; Path=/; Secure; SameSite=Lax");
            cookies.add("server_use=true; Path=/; Secure; SameSite=Lax");
            handler.post(()->setOneDriveCookies(cookies,0,address));
        }catch(Exception ignored){loginState("broker_error","api.oplist.org",-1);handler.post(()->toast("OneDrive 授权入口暂不可用，请检查网络后重新登录"));}});
    }
    private void setOneDriveCookies(List<String> cookies,int index,String address){
        if(completed)return;
        if(index==cookies.size()){CookieManager.getInstance().flush();web.loadUrl(address);return;}
        CookieManager.getInstance().setCookie("https://api.oplist.org/",cookies.get(index),
            success->setOneDriveCookies(cookies,index+1,address));
    }
    private static boolean official(String host,String... roots){
        if(host==null)return false;for(String root:roots)if(host.equals(root)||host.endsWith("."+root))return true;return false;
    }
    private boolean handoff(WebView current,Uri uri){
        String scheme=uri.getScheme()==null?"":uri.getScheme().toLowerCase(Locale.ROOT);
        String host=current.getUrl()==null?null:Uri.parse(current.getUrl()).getHost();
        if(host==null)host=popupOrigins.get(current);
        if(!official(host,"weiyun.com","qq.com","weixin.qq.com","quark.cn","alipan.com","aliyundrive.com"))return true;
        if(!Arrays.asList("intent","quark","uclink","qklink","ucweb","mqq","mqqapi","mqqopensdkapi","wtloginmqq","weixin","alipans","aliyundrive").contains(scheme))return true;
        try{
            Intent out="intent".equals(scheme)?Intent.parseUri(uri.toString(),Intent.URI_INTENT_SCHEME):new Intent(Intent.ACTION_VIEW,uri);
            out.setComponent(null);out.setSelector(null);out.setFlags(0);out.addCategory(Intent.CATEGORY_BROWSABLE);
            String target=out.getPackage();
            if(target!=null&&!(target.equals("com.tencent.mm")||target.equals("com.tencent.mobileqq")||target.equals("com.quark.browser")||target.equals("com.quark.clouddrive")||target.startsWith("com.alicloud.")||target.startsWith("com.aliyun.")))return true;
            if(Arrays.asList("uclink","qklink","ucweb","quark").contains(scheme))out.setPackage("com.quark.browser");
            if("weixin".equals(scheme))out.setPackage("com.tencent.mm");
            if(Arrays.asList("mqq","mqqapi","mqqopensdkapi","wtloginmqq").contains(scheme))out.setPackage("com.tencent.mobileqq");
            startActivity(out);
        }catch(Exception ignored){toast("未能拉起官方客户端，可继续使用官方网页入口");}
        return true;
    }
    private void capture(){if(!completed&&web!=null)captureFrom(web);}
    private void captureFrom(WebView current){
        if(completed||current.getUrl()==null)return;Uri uri=Uri.parse(current.getUrl());if(!"https".equals(uri.getScheme()))return;
        if(captureOneDrive(uri))return;
        if("ali".equals(provider)&&"www.alipan.com".equals(uri.getHost())){
            current.evaluateJavascript("(function(){try{return sessionStorage.getItem('token')||localStorage.getItem('token')||'';}catch(e){return '';}})()",raw->{
                try{Object value=new JSONTokener(raw).nextValue();if(!(value instanceof String))return;
                    JSONObject token=new JSONObject((String)value);if(!token.optString("access_token").isEmpty())finishToken(token.toString());
                }catch(Exception ignored){}
            });
        }
        if("tianyi".equals(provider)&&"h5.cloud.189.cn".equals(uri.getHost())){
            String query=uri.getQueryParameter("accessToken");if(query!=null&&!query.isEmpty())verifyCandidate(query);
            current.evaluateJavascript("(function(){try{var t=localStorage.getItem('accessToken')||'';try{var p=JSON.parse(t);if(typeof p==='string')t=p;}catch(e){}return t;}catch(e){return '';}})()",raw->{
                try{Object value=new JSONTokener(raw).nextValue();if(value instanceof String&&!((String)value).isEmpty())verifyCandidate((String)value);}catch(Exception ignored){}
            });
        }
        if("mobile139".equals(provider)&&official(uri.getHost(),"yun.139.com")){
            // Some Android WebViews omit Authorization from intercepted XHR
            // requests. The official mobile page also keeps the same grant in
            // its own authorization cookie, so polling works after login and
            // after reopening an existing official web session.
            String cookies=CookieManager.getInstance().getCookie(current.getUrl());
            if(cookies!=null)for(String entry:cookies.split(";")){
                int at=entry.indexOf('=');if(at<0||!"authorization".equals(entry.substring(0,at).trim()))continue;
                String candidate=Uri.decode(entry.substring(at+1).trim());
                if(candidate.startsWith("Basic "))verifyCandidate(candidate);
            }
        }
    }
    private synchronized void verifyCandidate(String value){
        if(completed||value.equals(lastCandidate)||value.length()>32768)return;lastCandidate=value;
        worker.execute(()->{try{
            CloudDrive drive="tianyi".equals(provider)?new TianyiCloudDrive(value):new MobileCloudDrive(value);
            drive.authenticate(false);
            if(drive instanceof TianyiCloudDrive)((TianyiCloudDrive)drive).listFolder("-11");
            else ((MobileCloudDrive)drive).listFolder("/");
            String token=drive.credentials.toString();handler.post(()->finishToken(token));
        }catch(Exception error){
            loginState("verification_failed","",-1,CloudNet.safeError(error));
            synchronized(CloudLoginActivity.this){lastCandidate="";}
        }});
    }
    private void pollRemote(){
        if(completed||pollBusy)return;
        if("quark".equals(provider)&&quark!=null&&!quarkPage.isEmpty()){
            pollBusy=true;worker.execute(()->{try{if(quark.pollLogin(quarkPage))handler.post(()->finishToken(quark.credentials.toString()));}
                catch(Exception ignored){}finally{pollBusy=false;}});
        }
        if("weiyun".equals(provider)&&!weiyunCode.isEmpty()){
            pollBusy=true;worker.execute(()->{try{
                CloudNet.Response response=CloudNet.request("POST","https://www.weiyun.com/api/v3/mcp/token/code",CloudNet.headers("Content-Type","application/json"),
                    CloudDrive.bytes(CloudDrive.obj("code",weiyunCode).toString()),65536);
                String token=new JSONObject(response.text()).optString("token");if(!token.isEmpty())handler.post(()->finishToken(token));
            }catch(Exception ignored){}finally{pollBusy=false;}});
        }
    }
    private void importClipboard(){
        ClipboardManager manager=(ClipboardManager)getSystemService(CLIPBOARD_SERVICE);ClipData clip=manager.getPrimaryClip();
        if(clip==null||clip.getItemCount()!=1){toast("请先复制微云官方安装指令");return;}
        String text=clip.getItemAt(0).coerceToText(this).toString();if(text.length()>32768){toast("安装指令过长");return;}
        java.util.regex.Matcher match=java.util.regex.Pattern.compile("(?:WEIYUN_)?MCP_TOKEN\\s*[=:]\\s*[\"']?([A-Za-z0-9_.-]{16,2048})",java.util.regex.Pattern.CASE_INSENSITIVE).matcher(text);
        String token=match.find()?match.group(1):text.trim();
        if(!token.matches("[A-Za-z0-9_.-]{16,2048}")){toast("未识别到官方 MCP Token");return;}
        if(android.os.Build.VERSION.SDK_INT>=28)manager.clearPrimaryClip();finishToken(token);
    }
    private boolean captureOneDrive(Uri uri){
        if(!completed&&"onedrive".equals(provider)&&"https".equals(uri.getScheme())&&"api.oplist.org".equals(uri.getHost())){
            String fragment=uri.getFragment();if(fragment!=null&&fragment.length()<100000)try{
                JSONObject data=new JSONObject(new String(Base64.decode(fragment,Base64.DEFAULT),StandardCharsets.UTF_8));
                if(!data.optString("refresh_token").isEmpty()){finishToken(data.toString());return true;}
            }catch(Exception ignored){}
        }return completed;
    }
    private void toast(String text){if(!completed)Toast.makeText(this,text,Toast.LENGTH_LONG).show();}
    private void loginState(String stage,String host,int code){
        loginState(stage,host,code,"");
    }
    private void loginState(String stage,String host,int code,String failure){
        if((getApplicationInfo().flags&android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE)==0)return;
        try(java.io.FileOutputStream output=openFileOutput("cloud_login_"+provider+".json",MODE_PRIVATE)){
            JSONObject report=CloudDrive.obj("provider",provider,"stage",stage,"host",host==null?"":host,
                "error_code",code,"authorized",stage.equals("authorized"));
            if(!failure.isEmpty())report.put("failure",failure);
            output.write(CloudDrive.bytes(report.toString()));
        }catch(Exception ignored){}
    }
    private void finishToken(String token){if(completed)return;loginState("authorized","",0);completed=true;CookieManager.getInstance().flush();
        setResult(RESULT_OK,new Intent().putExtra("token",token));finish();}
    @Override protected void onDestroy(){completed=true;handler.removeCallbacks(poll);worker.shutdownNow();
        if(content!=null)for(int i=0;i<content.getChildCount();i++){WebView view=(WebView)content.getChildAt(i);view.stopLoading();view.destroy();}
        web=null;super.onDestroy();
    }
}
