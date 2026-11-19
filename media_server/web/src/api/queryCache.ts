import { useCallback, useEffect, useRef, useState } from 'react';

interface CacheEntry<T = unknown> {
  data: T;
  fetchedAt: number;
}

const MAX_CACHE_ENTRIES = 160;
const cache = new Map<string, CacheEntry>();
const inFlight = new Map<string, Promise<unknown>>();

export function getCached<T>(key: string): T | undefined {
  const entry = cache.get(key);
  if (!entry) return undefined;
  // Refresh LRU order
  cache.delete(key);
  cache.set(key, entry);
  return entry.data as T;
}

export function getCachedAgeMs(key: string): number {
  const entry = cache.get(key);
  if (!entry) return Number.POSITIVE_INFINITY;
  return Date.now() - entry.fetchedAt;
}

export function setCached<T>(key: string, data: T): void {
  if (cache.has(key)) {
    cache.delete(key);
  }
  cache.set(key, { data, fetchedAt: Date.now() });
  while (cache.size > MAX_CACHE_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest === undefined) break;
    cache.delete(oldest);
  }
}

export function clearQueryCache(): void {
  cache.clear();
  inFlight.clear();
}

export async function fetchWithCache<T>(key: string, fetcher: () => Promise<T>): Promise<T> {
  const existing = inFlight.get(key);
  if (existing) {
    return existing as Promise<T>;
  }
  const promise = fetcher()
    .then((data) => {
      setCached(key, data);
      return data;
    })
    .finally(() => {
      inFlight.delete(key);
    });
  inFlight.set(key, promise);
  return promise;
}

export function prefetchQuery<T>(key: string, fetcher: () => Promise<T>, minStaleMs = 15000): void {
  if (!key) return;
  if (getCachedAgeMs(key) < minStaleMs || inFlight.has(key)) {
    return;
  }
  void fetchWithCache(key, fetcher).catch(() => {});
}

export interface UseSWRQueryOptions<T> {
  enabled?: boolean;
  deps?: ReadonlyArray<unknown>;
  keepPreviousData?: boolean;
  onError?: (err: Error) => void;
  onSuccess?: (data: T) => void;
}

export interface UseSWRQueryResult<T> {
  data: T | undefined;
  showSkeleton: boolean;
  isFetching: boolean;
  isStaleData: boolean;
  mutate: (next: T | ((prev: T | undefined) => T | undefined)) => void;
  reload: () => Promise<void>;
}

export function useSWRQuery<T>(
  key: string | null,
  fetcher: () => Promise<T>,
  options: UseSWRQueryOptions<T> = {}
): UseSWRQueryResult<T> {
  const { enabled = true, deps = [], keepPreviousData = false, onError, onSuccess } = options;

  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;
  const onErrorRef = useRef(onError);
  onErrorRef.current = onError;
  const onSuccessRef = useRef(onSuccess);
  onSuccessRef.current = onSuccess;

  const initialHit = key && enabled ? getCached<T>(key) : undefined;
  const [state, setState] = useState<{
    key: string | null;
    data: T | undefined;
    isFetching: boolean;
  }>({
    key,
    data: initialHit,
    isFetching: Boolean(key && enabled),
  });

  const activeKeyRef = useRef<string | null>(key);
  activeKeyRef.current = key;
  const reqSeqRef = useRef(0);

  // Synchronously resolve cache hit whenever key changes so rendered frame never flashes loading text.
  useEffect(() => {
    if (!key || !enabled) {
      setState((prev) => ({
        key,
        data: keepPreviousData ? prev.data : undefined,
        isFetching: false,
      }));
      return;
    }
    const cached = getCached<T>(key);
    setState((prev) => ({
      key,
      data: cached !== undefined ? cached : keepPreviousData ? prev.data : undefined,
      isFetching: true,
    }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, enabled, keepPreviousData]);

  const execute = useCallback(async () => {
    if (!key || !enabled) return;
    const myKey = key;
    const mySeq = ++reqSeqRef.current;
    setState((prev) => ({
      ...prev,
      isFetching: true,
    }));
    try {
      const fresh = await fetchWithCache(myKey, () => fetcherRef.current());
      if (activeKeyRef.current !== myKey || reqSeqRef.current !== mySeq) return;
      setState({
        key: myKey,
        data: fresh,
        isFetching: false,
      });
      onSuccessRef.current?.(fresh);
    } catch (err) {
      if (activeKeyRef.current !== myKey || reqSeqRef.current !== mySeq) return;
      setState((prev) => ({
        ...prev,
        isFetching: false,
      }));
      onErrorRef.current?.(err as Error);
    }
  }, [key, enabled]);

  useEffect(() => {
    void execute();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [execute, ...deps]);

  const mutate = useCallback(
    (next: T | ((prev: T | undefined) => T | undefined)) => {
      setState((prev) => {
        const value =
          typeof next === 'function'
            ? (next as (p: T | undefined) => T | undefined)(prev.data)
            : next;
        if (value === undefined) {
          return prev;
        }
        if (key) {
          setCached(key, value);
        }
        return {
          ...prev,
          data: value,
        };
      });
    },
    [key]
  );

  // Immediately inspect cache on the very first render after key transition before effect flushes.
  let resolvedData = state.data;
  if (key && enabled && state.key !== key) {
    const syncHit = getCached<T>(key);
    if (syncHit !== undefined) {
      resolvedData = syncHit;
    } else if (!keepPreviousData) {
      resolvedData = undefined;
    }
  }

  const showSkeleton = Boolean(enabled && key && resolvedData === undefined && state.isFetching);
  const isStaleData = Boolean(key && state.key !== key && resolvedData !== undefined);

  return {
    data: resolvedData,
    showSkeleton,
    isFetching: state.isFetching,
    isStaleData,
    mutate,
    reload: execute,
  };
}
