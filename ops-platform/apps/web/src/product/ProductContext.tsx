import {
  createContext,
  type ReactNode,
  useContext,
  useEffect,
  useMemo,
  useState
} from "react";
import { opsClient, type ProductRecord } from "../api/client";

const productStorageKey = "stacio.ops.productId";
const defaultProductId = "stacio";

interface ProductContextValue {
  provided: boolean;
  products: ProductRecord[];
  productId: string;
  activeProduct?: ProductRecord;
  loading: boolean;
  error?: string;
  setProductId: (productId: string) => void;
}

const ProductContext = createContext<ProductContextValue>({
  provided: false,
  products: [],
  productId: defaultProductId,
  activeProduct: undefined,
  loading: false,
  error: undefined,
  setProductId: () => undefined
});

function storedProductId() {
  if (typeof window === "undefined") {
    return defaultProductId;
  }
  return window.localStorage.getItem(productStorageKey) ?? defaultProductId;
}

export function ProductProvider({ children }: { children: ReactNode }) {
  const [products, setProducts] = useState<ProductRecord[]>([]);
  const [productId, setProductIdState] = useState(storedProductId);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();

  useEffect(() => {
    let cancelled = false;

    void opsClient
      .products()
      .then((items) => {
        if (cancelled) {
          return;
        }
        setProducts(items);
        const stored = storedProductId();
        const nextProductId = items.some((item) => item.id === stored)
          ? stored
          : items.find((item) => item.id === defaultProductId)?.id
            ?? items[0]?.id
            ?? defaultProductId;
        setProductIdState(nextProductId);
        window.localStorage.setItem(productStorageKey, nextProductId);
        setError(undefined);
      })
      .catch((caught: unknown) => {
        if (!cancelled) {
          setError(caught instanceof Error ? caught.message : "产品列表加载失败");
        }
      })
      .finally(() => {
        if (!cancelled) {
          setLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, []);

  const value = useMemo<ProductContextValue>(
    () => ({
      provided: true,
      products,
      productId,
      activeProduct: products.find((item) => item.id === productId),
      loading,
      error,
      setProductId(nextProductId) {
        if (!nextProductId) {
          return;
        }
        setProductIdState(nextProductId);
        window.localStorage.setItem(productStorageKey, nextProductId);
      }
    }),
    [error, loading, productId, products]
  );

  return <ProductContext.Provider value={value}>{children}</ProductContext.Provider>;
}

export function useProduct() {
  return useContext(ProductContext);
}

export function useProductSelection() {
  const context = useContext(ProductContext);
  const [fallbackProducts, setFallbackProducts] = useState<ProductRecord[]>([]);
  const [fallbackProductId, setFallbackProductId] = useState(defaultProductId);
  const [fallbackLoading, setFallbackLoading] = useState(!context.provided);
  const [fallbackError, setFallbackError] = useState<string>();

  useEffect(() => {
    if (context.provided) {
      return;
    }

    let cancelled = false;
    setFallbackLoading(true);
    void opsClient
      .products()
      .then((items) => {
        if (cancelled) {
          return;
        }
        setFallbackProducts(items);
        setFallbackProductId((current) =>
          items.some((item) => item.id === current)
            ? current
            : items.find((item) => item.id === defaultProductId)?.id
              ?? items[0]?.id
              ?? defaultProductId
        );
        setFallbackError(undefined);
      })
      .catch((caught: unknown) => {
        if (!cancelled) {
          setFallbackError(caught instanceof Error ? caught.message : "产品列表加载失败");
        }
      })
      .finally(() => {
        if (!cancelled) {
          setFallbackLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [context.provided]);

  const fallbackValue = useMemo<ProductContextValue>(
    () => ({
      provided: false,
      products: fallbackProducts,
      productId: fallbackProductId,
      activeProduct: fallbackProducts.find((item) => item.id === fallbackProductId),
      loading: fallbackLoading,
      error: fallbackError,
      setProductId(nextProductId) {
        if (nextProductId) {
          setFallbackProductId(nextProductId);
        }
      }
    }),
    [fallbackError, fallbackLoading, fallbackProductId, fallbackProducts]
  );

  return context.provided ? context : fallbackValue;
}
