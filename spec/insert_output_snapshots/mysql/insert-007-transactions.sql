SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;
INSERT INTO `transactions` (`id`, `type`, `amount`, `order_id`, `updated_at`, `created_at`) VALUES
('3', 'PaymentTransaction', '30.00', '3', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
('4', 'PaymentTransaction', '10.00', '4', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
('5', 'PaymentTransaction', '20.00', '5', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
('6', 'PaymentTransaction', '30.00', '6', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000');
SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;
