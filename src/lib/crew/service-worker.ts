/** Registering and tidying the Crew service worker (public/crew-sw.js). Production only: in development a
 *  caching worker only gets in the way. */

export async function registerCrewServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (typeof window === 'undefined' || !('serviceWorker' in navigator) || !import.meta.env.PROD) return null
  try {
    return await navigator.serviceWorker.register('/crew-sw.js', { scope: '/crew', updateViaCache: 'none' })
  } catch {
    return null
  }
}

/** Empty the worker's caches, e.g. on sign-out. Asks the worker (which then restores its offline page) and, if
 *  there is no active worker, clears the caches directly. Never throws. */
export async function clearCrewCaches(): Promise<void> {
  if (typeof window === 'undefined') return
  try {
    const reg = 'serviceWorker' in navigator ? await navigator.serviceWorker.getRegistration('/crew') : undefined
    const worker = reg?.active
    if (worker) {
      await new Promise<void>((resolve) => {
        const channel = new MessageChannel()
        const timer = window.setTimeout(resolve, 3000)
        channel.port1.onmessage = () => {
          window.clearTimeout(timer)
          resolve()
        }
        worker.postMessage({ type: 'CLEAR_CACHES' }, [channel.port2])
      })
      return
    }
    if ('caches' in window) {
      const keys = await caches.keys()
      await Promise.all(keys.filter((k) => k.startsWith('crew-')).map((k) => caches.delete(k)))
    }
  } catch {
    // Nothing useful to do: the worker holds no user data in any case.
  }
}
