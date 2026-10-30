package com.fqapp.fqapp;
import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.*;
import android.util.Base64;
import android.webkit.*;
import android.widget.*;
import org.json.*;
import java.nio.charset.StandardCharsets;

/** User operates the official login page. Only trusted final origins can return
 * credentials; there is no JavaScript bridge, cookie dump, or credential log. */
public final class CloudLoginActivity extends Activity {
    private WebView web;
    private String provider;
    private boolean completed;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final Runnable poll=new Runnable(){public void run(){capture();if(!completed)handler.postDelayed(this,1200);}};
    public void onCreate(Bundle state){
        super.onCreate(state);provider=getIntent().getStringExtra("provider");
        LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.VERTICAL);
        Button done=new Button(this);done.setText("完成登录 / 检查授权");done.setOnClickListener(v->capture());layout.addView(done);
        web=new WebView(this);layout.addView(web,new LinearLayout.LayoutParams(-1,0,1));setContentView(layout);
        WebSettings settings=web.getSettings();settings.setJavaScriptEnabled(true);settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);settings.setAllowContentAccess(false);settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        CookieManager.getInstance().setAcceptCookie(true);
        web.setWebViewClient(new WebViewClient(){
            public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request){
                Uri uri=request.getUrl();
                if(captureOneDrive(uri))return true;
                if("https".equals(uri.getScheme()))return false;
                // Do not execute intent:, file:, or javascript: supplied by a page.
                return true;
            }
            public void onPageStarted(WebView view,String url,android.graphics.Bitmap icon){captureOneDrive(Uri.parse(url));}
            public void onPageFinished(WebView view,String url){capture();}
        });
        if("ali".equals(provider))web.loadUrl("https://www.alipan.com/sign/in");
        else web.loadUrl("https://api.oplist.org/onedrive/requests?driver_txt=onedrive_pr&server_use=true");
        handler.postDelayed(poll,1200);
    }
    private void capture(){
        if(completed||web==null||web.getUrl()==null)return;
        Uri uri=Uri.parse(web.getUrl());if(!"https".equals(uri.getScheme()))return;
        if(captureOneDrive(uri))return;
        if("ali".equals(provider)&&"www.alipan.com".equals(uri.getHost())){
            web.evaluateJavascript("(function(){try{return sessionStorage.getItem('token')||localStorage.getItem('token')||'';}catch(e){return '';}})()",raw->{
                try{
                    Object value=new JSONTokener(raw).nextValue();if(!(value instanceof String))return;
                    JSONObject token=new JSONObject((String)value);
                    if(!token.optString("access_token").isEmpty())finishToken(token.toString());
                }catch(Exception ignored){}
            });
        }
    }
    private boolean captureOneDrive(Uri uri){
        if(!completed&&"onedrive".equals(provider)&&"https".equals(uri.getScheme())&&"api.oplist.org".equals(uri.getHost())){
            String fragment=uri.getFragment();
            if(fragment!=null&&fragment.length()<100000)try{
                String token=new String(Base64.decode(fragment,Base64.DEFAULT),StandardCharsets.UTF_8);
                JSONObject data=new JSONObject(token);
                if(!data.optString("refresh_token").isEmpty()){finishToken(data.toString());return true;}
            }catch(Exception ignored){}
        }
        return completed;
    }
    private void finishToken(String token){if(completed)return;completed=true;
        setResult(RESULT_OK,new Intent().putExtra("token",token));finish();}
    protected void onDestroy(){completed=true;handler.removeCallbacks(poll);if(web!=null){web.stopLoading();web.destroy();web=null;}super.onDestroy();}
}
