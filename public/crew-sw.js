/*
 * Duly Crew service worker. Scope: /crew (see src/lib/crew/service-worker.ts).
 *
 * What it does: lets the Crew app open without a signal, by keeping the app's own static files and the last good
 * copy of each Crew page, and showing a plain "you're offline" page for a page it has never seen.
 *
 * What it deliberately does not do:
 *   - It never touches anything that isn't a plain GET to this site: no Supabase, no API routes, no postcode or map
 *     lookups, no uploads. Data always comes from the network, so nobody ever sees stale jobs or someone else's data.
 *   - It caches no user data. Crew pages are the same shell for everyone (the person is identified in the browser,
 *     not in the HTML), and it refuses to store anything marked private or no-store.
 *   - It does not queue check-ins, ticks or completions. Those carry a time and a place that must be real.
 *     (Photos that can't upload are queued by the app itself, in IndexedDB.)
 *
 * Plain JavaScript, no build step. Bump VERSION to retire old caches.
 */
'use strict'

var VERSION = 'v1'
var SHELL = 'crew-shell-' + VERSION // the offline page, icons and manifest
var ASSETS = 'crew-assets-' + VERSION // hashed build files and web fonts
var PAGES = 'crew-pages-' + VERSION // last good HTML of Crew pages
var CURRENT = [SHELL, ASSETS, PAGES]

var OFFLINE_URL = '/crew-offline.html'
var PRECACHE = [OFFLINE_URL, '/crew.webmanifest', '/icon.svg', '/icons/icon-192.png', '/icons/icon-512.png']
var FONT_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com']
var MAX_ASSETS = 120
var MAX_PAGES = 12
var NAVIGATION_TIMEOUT_MS = 4000

function isCrewPage(pathname) {
  return pathname === '/crew' || pathname.indexOf('/crew/') === 0
}

// Never keep a response the server marked private or no-store, a redirect, or an error.
function cacheable(response) {
  if (!response || !response.ok || response.redirected) return false
  var control = (response.headers.get('cache-control') || '').toLowerCase()
  return control.indexOf('no-store') === -1 && control.indexOf('private') === -1
}

function trim(cache, max) {
  return cache.keys().then(function (keys) {
    var extra = keys.length - max
    if (extra <= 0) return undefined
    return Promise.all(keys.slice(0, extra).map(function (key) { return cache.delete(key) }))
  })
}

function precache() {
  return caches.open(SHELL).then(function (cache) { return cache.addAll(PRECACHE) })
}

self.addEventListener('install', function (event) {
  event.waitUntil(precache().then(function () { return self.skipWaiting() }))
})

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches
      .keys()
      .then(function (keys) {
        return Promise.all(
          keys
            .filter(function (key) { return key.indexOf('crew-') === 0 && CURRENT.indexOf(key) === -1 })
            .map(function (key) { return caches.delete(key) }),
        )
      })
      .then(function () { return self.clients.claim() }),
  )
})

// Signing out wipes everything this worker has stored (it holds no user data, but a shared phone should be clean).
self.addEventListener('message', function (event) {
  if (!event.data || event.data.type !== 'CLEAR_CACHES') return
  event.waitUntil(
    caches
      .keys()
      .then(function (keys) {
        return Promise.all(keys.filter(function (key) { return key.indexOf('crew-') === 0 }).map(function (key) { return caches.delete(key) }))
      })
      .then(precache)
      .catch(function () {})
      .then(function () {
        if (event.ports && event.ports[0]) event.ports[0].postMessage({ type: 'CLEARED' })
      }),
  )
})

function withTimeout(promise, ms) {
  return new Promise(function (resolve, reject) {
    var timer = setTimeout(function () { reject(new Error('timeout')) }, ms)
    promise.then(
      function (value) { clearTimeout(timer); resolve(value) },
      function (error) { clearTimeout(timer); reject(error) },
    )
  })
}

// Crew pages: the network first, so people always get the current app; the saved copy only when there is no network.
function navigate(request) {
  var key = new URL(request.url).pathname
  return withTimeout(fetch(request), NAVIGATION_TIMEOUT_MS)
    .then(function (response) {
      var type = (response.headers.get('content-type') || '').toLowerCase()
      if (cacheable(response) && type.indexOf('text/html') !== -1) {
        var copy = response.clone()
        caches.open(PAGES).then(function (cache) { return cache.put(key, copy).then(function () { return trim(cache, MAX_PAGES) }) })
      }
      return response
    })
    .catch(function () {
      return caches.open(PAGES).then(function (pages) {
        return pages.match(key).then(function (saved) {
          if (saved) return saved
          return caches
            .open(SHELL)
            .then(function (shell) { return shell.match(OFFLINE_URL) })
            .then(function (offline) { return offline || Response.error() })
        })
      })
    })
}

// Hashed build files never change, so the saved copy is always right.
function cacheFirst(request, name, max) {
  return caches.open(name).then(function (cache) {
    return cache.match(request).then(function (saved) {
      if (saved) return saved
      return fetch(request).then(function (response) {
        if (cacheable(response)) cache.put(request, response.clone()).then(function () { return trim(cache, max) })
        return response
      })
    })
  })
}

// Fonts: show what is saved at once and refresh it in the background.
function staleWhileRevalidate(request, name, max) {
  return caches.open(name).then(function (cache) {
    return cache.match(request).then(function (saved) {
      var refresh = fetch(request)
        .then(function (response) {
          // A cross-origin stylesheet comes back opaque (status 0); that is fine to keep.
          if (response && (response.ok || response.type === 'opaque')) cache.put(request, response.clone()).then(function () { return trim(cache, max) })
          return response
        })
        .catch(function () { return saved })
      return saved || refresh
    })
  })
}

function staticFile(request) {
  return caches.open(SHELL).then(function (cache) {
    return cache.match(request).then(function (saved) {
      var refresh = fetch(request)
        .then(function (response) {
          if (cacheable(response)) cache.put(request, response.clone())
          return response
        })
        .catch(function () { return saved })
      return saved || refresh
    })
  })
}

self.addEventListener('fetch', function (event) {
  var request = event.request
  if (request.method !== 'GET') return
  var url = new URL(request.url)

  if (url.origin === self.location.origin) {
    if (request.mode === 'navigate') {
      if (isCrewPage(url.pathname)) event.respondWith(navigate(request))
      return
    }
    if (url.pathname.indexOf('/assets/') === 0) {
      event.respondWith(cacheFirst(request, ASSETS, MAX_ASSETS))
      return
    }
    if (PRECACHE.indexOf(url.pathname) !== -1) {
      event.respondWith(staticFile(request))
      return
    }
    return // everything else on this site (API routes, data) goes straight to the network
  }

  if (FONT_HOSTS.indexOf(url.hostname) !== -1) {
    event.respondWith(staleWhileRevalidate(request, ASSETS, MAX_ASSETS))
  }
  // any other site (Supabase, postcode lookup, maps) is never touched
})
