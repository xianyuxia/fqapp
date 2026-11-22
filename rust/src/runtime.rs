#[cfg(not(target_arch = "wasm32"))]
pub(crate) use tokio::time::{sleep, timeout, timeout_at, Instant};

#[cfg(target_arch = "wasm32")]
pub(crate) use browser::*;

#[cfg(target_arch = "wasm32")]
mod browser {
    use futures::{channel::oneshot, future};
    use std::{future::Future, time::Duration};
    use wasm_bindgen::{prelude::*, JsCast};

    pub use web_time::Instant;

    #[wasm_bindgen]
    extern "C" {
        #[wasm_bindgen(js_namespace = globalThis, js_name = setTimeout)]
        fn set_timeout(callback: &js_sys::Function, milliseconds: i32) -> i32;

        #[wasm_bindgen(js_namespace = globalThis, js_name = clearTimeout)]
        fn clear_timeout(id: i32);
    }

    struct Timer {
        id: i32,
        _callback: Closure<dyn FnMut()>,
    }

    impl Drop for Timer {
        fn drop(&mut self) {
            clear_timeout(self.id);
        }
    }

    // The timer and its JS closure stay in the browser task. Callers only await
    // the oneshot, keeping the existing Send contract of endpoint futures.
    pub async fn sleep(delay: Duration) {
        let (mut send, receive) = oneshot::channel();
        wasm_bindgen_futures::spawn_local(async move {
            let (complete, done) = oneshot::channel();
            let mut complete = Some(complete);
            let callback = Closure::wrap(Box::new(move || {
                if let Some(complete) = complete.take() {
                    let _ = complete.send(());
                }
            }) as Box<dyn FnMut()>);
            let id = set_timeout(
                callback.as_ref().unchecked_ref(),
                delay.as_millis().min(i32::MAX as u128) as i32,
            );
            let timer = Timer {
                id,
                _callback: callback,
            };
            let outcome = future::select(done, send.cancellation()).await;
            let completed = matches!(outcome, future::Either::Left(_));
            drop(outcome);
            if completed {
                let _ = send.send(());
            }
            drop(timer);
        });
        let _ = receive.await;
    }

    pub async fn timeout<F: Future>(limit: Duration, work: F) -> Result<F::Output, ()> {
        timeout_at(Instant::now() + limit, work).await
    }

    pub async fn timeout_at<F: Future>(deadline: Instant, work: F) -> Result<F::Output, ()> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(());
        }
        match future::select(Box::pin(work), Box::pin(sleep(remaining))).await {
            future::Either::Left((value, _)) if Instant::now() < deadline => Ok(value),
            _ => Err(()),
        }
    }
}
