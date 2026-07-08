SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;
INSERT INTO `products` (`id`, `name`, `price`, `shop_id`, `updated_at`, `created_at`) VALUES
('1', 'product-1-masked', '10.00', '1', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
('2', 'product-2-masked', '20.00', '1', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
('3', 'product-3-masked', '30.00', '1', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000');
SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;
