use std::{future::Future, time::Duration};

use crate::runtime::{sleep, timeout_at, Instant};

pub(crate) const HTTP_REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

#[cfg(not(target_arch = "wasm32"))]
tokio::task_local! {
    static DEADLINE: Instant;
}

#[cfg(target_arch = "wasm32")]
thread_local! {
    static DEADLINE: std::cell::Cell<Option<Instant>> = const { std::cell::Cell::new(None) };
}

#[cfg(not(target_arch = "wasm32"))]
async fn scoped<F: Future>(deadline: Instant, work: F) -> F::Output {
    DEADLINE.scope(deadline, work).await
}

#[cfg(target_arch = "wasm32")]
async fn scoped<F: Future>(deadline: Instant, work: F) -> F::Output {
    // Set the budget for each poll, rather than leaking it to concurrently
    // pending requests on the same browser thread.
    let mut work = std::pin::pin!(work);
    std::future::poll_fn(|context| {
        struct Restore(Option<Instant>);
        impl Drop for Restore {
            fn drop(&mut self) {
                DEADLINE.set(self.0);
            }
        }
        let _restore = Restore(DEADLINE.replace(Some(deadline)));
        work.as_mut().poll(context)
    })
    .await
}

pub(crate) async fn within<F: Future>(limit: Duration, work: F) -> Result<F::Output, ()> {
    let deadline = Instant::now() + limit;
    scoped(deadline, async {
        let result = timeout_at(deadline, work).await.map_err(|_| ())?;
        if Instant::now() >= deadline {
            Err(())
        } else {
            Ok(result)
        }
    })
    .await
}

pub(crate) fn remaining() -> Option<Duration> {
    #[cfg(not(target_arch = "wasm32"))]
    let deadline = DEADLINE.try_with(|value| *value).ok();
    #[cfg(target_arch = "wasm32")]
    let deadline = DEADLINE.get();
    deadline.map(|value| value.saturating_duration_since(Instant::now()))
}

pub(crate) fn cap_timeout(limit: Duration) -> Duration {
    remaining().map_or(limit, |left| left.min(limit))
}

pub(crate) async fn retry_pause(delay: Duration) -> bool {
    if remaining().is_some_and(|left| left <= delay) {
        return false;
    }
    sleep(delay).await;
    !remaining().is_some_and(|left| left.is_zero())
}
