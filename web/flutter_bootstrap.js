{{flutter_js}}
{{flutter_build_config}}

const shijinpuFlutterHost = document.getElementById('pwa-edge-host');
const reportStartupError = (error) => {
  console.error(error);
  window.dispatchEvent(new Event('pwa-startup-error'));
};
const config = shijinpuFlutterHost ? {hostElement: shijinpuFlutterHost} : {};
_flutter.loader.load({
  config,
  onEntrypointLoaded: async (engineInitializer) => {
    window.dispatchEvent(new Event('pwa-startup-initializing'));
    try {
      const app = await engineInitializer.initializeEngine(config);
      await app.runApp();
    } catch (error) {
      reportStartupError(error);
    }
  },
}).catch(reportStartupError);
