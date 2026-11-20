package br.com.rlentregas;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.webkit.CookieManager;
import android.webkit.GeolocationPermissions;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

/**
 * Central RL — app Android.
 * Abre o sistema online da Central numa tela própria. Como o conteúdo vem da internet,
 * toda melhoria publicada no site chega no app sem precisar instalar um APK novo.
 */
public class MainActivity extends Activity {

    /** Endereço fixo de entrada. A página /central/ decide para onde ir (teste ou oficial). */
    private static final String INICIO = "https://darioluizrl.github.io/rlmotoboy/central/";
    private static final String[] HOSTS_INTERNOS = {
        "darioluizrl.github.io", "rlentregas.com.br", "www.rlentregas.com.br"
    };
    private static final int REQ_LOCAL = 10;
    private static final int REQ_ARQUIVO = 11;

    private WebView web;
    private ValueCallback<Uri[]> arquivoCallback;
    private GeolocationPermissions.Callback geoCallback;
    private String geoOrigem;

    @Override
    protected void onCreate(Bundle salvo) {
        super.onCreate(salvo);
        web = new WebView(this);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);          // mantém o login (Supabase guarda a sessão aqui)
        s.setDatabaseEnabled(true);
        s.setGeolocationEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setUserAgentString(s.getUserAgentString() + " CentralRL-App/1");
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                return abrirFora(req.getUrl());
            }
            @Override
            public void onPageStarted(WebView v, String url, Bitmap icon) { super.onPageStarted(v, url, icon); }
        });

        web.setWebChromeClient(new WebChromeClient() {
            // localização: pede a permissão do Android e libera para a página
            @Override
            public void onGeolocationPermissionsShowPrompt(String origem, GeolocationPermissions.Callback cb) {
                if (!hostInterno(Uri.parse(origem))) { cb.invoke(origem, false, false); return; }
                if (temLocalizacao()) { cb.invoke(origem, true, false); return; }
                geoOrigem = origem; geoCallback = cb;
                requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION}, REQ_LOCAL);
            }
            // envio de documentos do cadastro (foto, PDF)
            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
                if (arquivoCallback != null) arquivoCallback.onReceiveValue(null);
                arquivoCallback = cb;
                try {
                    Intent i = p.createIntent();
                    i.addCategory(Intent.CATEGORY_OPENABLE);
                    startActivityForResult(Intent.createChooser(i, "Escolher arquivo"), REQ_ARQUIVO);
                } catch (ActivityNotFoundException e) {
                    arquivoCallback = null;
                    Toast.makeText(MainActivity.this, "Nenhum app para escolher arquivos", Toast.LENGTH_LONG).show();
                    return false;
                }
                return true;
            }
        });

        Uri link = getIntent() != null ? getIntent().getData() : null;
        if (salvo != null) web.restoreState(salvo);
        else web.loadUrl(link != null && hostInterno(link) ? link.toString() : INICIO + "?t=" + System.currentTimeMillis());
    }

    private boolean hostInterno(Uri u) {
        if (u == null || u.getHost() == null || !"https".equals(u.getScheme())) return false;
        for (String h : HOSTS_INTERNOS) if (h.equalsIgnoreCase(u.getHost())) return true;
        return false;
    }

    /** Links da Central ficam no app; Google Maps, WhatsApp, telefone etc. abrem no app certo do celular. */
    private boolean abrirFora(Uri u) {
        if (hostInterno(u)) return false;
        String esq = u.getScheme() == null ? "" : u.getScheme();
        if (esq.equals("https") && u.getHost() != null && u.getHost().endsWith(".supabase.co")) return false;
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, u));
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "Não há app para abrir este link", Toast.LENGTH_SHORT).show();
        }
        return true;
    }

    private boolean temLocalizacao() {
        return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            || checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] perms, int[] res) {
        super.onRequestPermissionsResult(req, perms, res);
        if (req == REQ_LOCAL && geoCallback != null) {
            geoCallback.invoke(geoOrigem, temLocalizacao(), false);
            geoCallback = null; geoOrigem = null;
        }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent dados) {
        super.onActivityResult(req, res, dados);
        if (req != REQ_ARQUIVO || arquivoCallback == null) return;
        Uri[] r = WebChromeClient.FileChooserParams.parseResult(res, dados);
        arquivoCallback.onReceiveValue(r);
        arquivoCallback = null;
    }

    @Override
    protected void onNewIntent(Intent i) {
        super.onNewIntent(i);
        Uri link = i.getData();
        if (link != null && hostInterno(link)) web.loadUrl(link.toString());
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) web.goBack(); else super.onBackPressed();
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    @Override protected void onPause() { super.onPause(); web.onPause(); CookieManager.getInstance().flush(); }
    @Override protected void onResume() { super.onResume(); web.onResume(); }
}
