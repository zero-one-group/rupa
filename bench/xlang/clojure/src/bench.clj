;; bench/xlang/clojure/src/bench.clj — Malli's column.
;;
;; One line out: `<name> <ns/op> <iterations>`. See bench/xlang/README.md.
;;
;; jsonista parses, `m/decoder` converts, `m/validator` checks. Both of those are compiled once
;; outside the loop, which is Malli's own advice and the same arrangement Rupa gets from `as:`.
;; clojure.spec would be the easier opponent and is the one Malli exists to replace, so it is
;; not the one here.

(ns bench
  (:require [jsonista.core :as j]
            [malli.core :as m]
            [malli.transform :as mt]))

(def non-empty [:string {:min 1}])

(def Payload
  [:map
   [:id non-empty]
   [:name non-empty]
   [:active :boolean]
   [:score [:double {:min 0}]]
   [:profile [:map
              [:age [:int {:min 0 :max 150}]]
              [:city :string]
              [:settings [:map
                          [:theme :string]
                          [:size :int]]]]]
   [:tags [:vector non-empty]]])

(def mapper (j/object-mapper {:decode-key-fn true}))
(def decode-value (m/decoder Payload (mt/json-transformer)))
(def valid? (m/validator Payload))

(defn decode [^String text]
  (let [value (decode-value (j/read-value text mapper))]
    (when (valid? value) value)))

(defn env-int [name fallback]
  (if-let [value (System/getenv name)] (Long/parseLong value) fallback))

(defn -main [& args]
  (let [path (first args)
        text (slurp path)]

    ;; The fixture has to decode before anything is timed, so a fast column can never be one
    ;; that quietly failed.
    (when-not (decode text)
      (throw (ex-info "the fixture did not decode" {:path path})))

    ;; Both are read from the environment so every column can be re-run at a different warmup
    ;; with one variable. This column needs it most: HotSpot's tiered compiler does not reach
    ;; its top tier until something like fifteen thousand invocations, so a warmup near ten
    ;; thousand measures C1 with profiling rather than C2, and reads as a slow library.
    (let [warmup (env-int "XLANG_WARMUP" 50000)
          iterations (env-int "XLANG_ITERATIONS" 100000)]
      (dotimes [_ warmup] (decode text))

      (let [started (System/nanoTime)
            _ (dotimes [_ iterations] (decode text))
            elapsed (- (System/nanoTime) started)]
        (printf "malli %.1f %d%n" (double (/ elapsed iterations)) iterations)
        (flush)))))
