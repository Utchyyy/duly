import { HeadContent, Scripts, createRootRoute } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { AuthProvider } from '#/lib/auth'

import appCss from '../styles.css?url'

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1, viewport-fit=cover' },
      { name: 'theme-color', content: '#1F5C45' },
      { title: 'Duly' },
      { name: 'description', content: 'Find verified cleaners, agree the brief, pay when it is done properly.' },
    ],
    links: [
      { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
      { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossOrigin: 'anonymous' },
      {
        rel: 'stylesheet',
        href: 'https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,600&family=Instrument+Sans:wght@400;500;600&display=swap',
      },
      { rel: 'stylesheet', href: appCss },
      { rel: 'icon', href: '/icon.svg', type: 'image/svg+xml' },
    ],
  }),
  shellComponent: RootDocument,
  notFoundComponent: () => (
    <div className="p-10 text-center">
      <h1 className="text-3xl">Page not found</h1>
      <a href="/" className="btn btn-ghost mt-4">
        Go to Duly
      </a>
    </div>
  ),
})

function RootDocument({ children }: { children: ReactNode }) {
  return (
    <html lang="en-GB">
      <head>
        <HeadContent />
      </head>
      <body>
        <AuthProvider>{children}</AuthProvider>
        <Scripts />
      </body>
    </html>
  )
}
