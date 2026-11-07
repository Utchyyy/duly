import type { OutboxEntry, OutboxStore } from './outbox.ts'

/** The outbox on the phone, in IndexedDB (which can hold photos). Every entry carries the person it belongs to. */
const DB_NAME = 'duly-crew'
const STORE = 'photo-outbox'

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === 'undefined') return reject(new Error('This phone cannot save photos for later.'))
    const request = indexedDB.open(DB_NAME, 1)
    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: 'id' })
        store.createIndex('userId', 'userId')
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(new Error('This phone cannot save photos for later.'))
  })
}

function run<T>(mode: IDBTransactionMode, work: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return open().then(
    (db) =>
      new Promise<T>((resolve, reject) => {
        const tx = db.transaction(STORE, mode)
        const request = work(tx.objectStore(STORE))
        let value: T
        request.onsuccess = () => {
          value = request.result
        }
        tx.oncomplete = () => {
          db.close()
          resolve(value)
        }
        tx.onerror = tx.onabort = () => {
          db.close()
          reject(tx.error ?? new Error('This phone could not save the photo.'))
        }
      }),
  )
}

export const idbOutbox: OutboxStore = {
  list: (userId) => run('readonly', (s) => s.index('userId').getAll(userId) as IDBRequest<OutboxEntry[]>),
  put: (entry) => run('readwrite', (s) => s.put(entry)).then(() => undefined),
  remove: (id) => run('readwrite', (s) => s.delete(id)).then(() => undefined),
}
