import { useEffect, useRef } from "react";

/**
 * Subscribes to the server-sent events stream (/api/v1/events).
 * EventSource reconnects automatically with backoff on error/close.
 *
 * @param handlers map of event name -> payload handler (JSON decoded)
 * @param deps re-subscribe when these change (handlers are captured)
 */
export function useEvents(
  handlers: Record<string, (payload: unknown) => void>,
  deps: unknown[] = [],
) {
  const handlersRef = useRef(handlers);
  handlersRef.current = handlers;

  useEffect(() => {
    const es = new EventSource("/api/v1/events");
    const names = Object.keys(handlersRef.current);
    const listeners: Array<[string, EventListener]> = names.map((name) => {
      const fn: EventListener = (ev) => {
        const msg = ev as MessageEvent;
        let payload: unknown = null;
        if (msg.data) {
          try {
            payload = JSON.parse(msg.data as string);
          } catch {
            payload = msg.data;
          }
        }
        handlersRef.current[name]?.(payload);
      };
      es.addEventListener(name, fn);
      return [name, fn];
    });
    return () => {
      for (const [name, fn] of listeners) es.removeEventListener(name, fn);
      es.close();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}
