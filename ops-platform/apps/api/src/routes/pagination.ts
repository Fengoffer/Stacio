import { z } from "zod";

export const paginationQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  page_size: z.coerce.number().int().min(1).max(100).default(20)
});

export type PaginationQuery = z.infer<typeof paginationQuerySchema>;

export interface PaginationMeta {
  total: number;
  page: number;
  page_size: number;
  total_pages: number;
  has_next: boolean;
  has_prev: boolean;
}

export function paginate<T>(items: T[], query: PaginationQuery) {
  const total = items.length;
  const totalPages = Math.ceil(total / query.page_size);
  const start = (query.page - 1) * query.page_size;
  const data = items.slice(start, start + query.page_size);
  const pagination: PaginationMeta = {
    total,
    page: query.page,
    page_size: query.page_size,
    total_pages: totalPages,
    has_next: query.page < totalPages,
    has_prev: query.page > 1
  };

  return {
    data,
    pagination
  };
}
