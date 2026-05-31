-- MySQL dump 10.13  Distrib 9.2.0, for Linux (x86_64)
--
-- Host: localhost    Database: exwiw_seed
-- ------------------------------------------------------
-- Server version	9.2.0

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `ar_internal_metadata`
--

DROP TABLE IF EXISTS `ar_internal_metadata`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `ar_internal_metadata` (
  `key` varchar(255) NOT NULL,
  `value` varchar(255) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `ar_internal_metadata`
--

LOCK TABLES `ar_internal_metadata` WRITE;
/*!40000 ALTER TABLE `ar_internal_metadata` DISABLE KEYS */;
INSERT INTO `ar_internal_metadata` VALUES ('environment','default_env','2025-02-11 05:56:23.608849','2025-02-11 05:56:23.608852');
/*!40000 ALTER TABLE `ar_internal_metadata` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `order_items`
--

DROP TABLE IF EXISTS `order_items`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `order_items` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `order_id` bigint NOT NULL,
  `product_id` bigint NOT NULL,
  `quantity` int NOT NULL DEFAULT '1',
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_order_items_on_order_id` (`order_id`),
  KEY `index_order_items_on_product_id` (`product_id`),
  CONSTRAINT `fk_rails_e3cb28f071` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`),
  CONSTRAINT `fk_rails_f1a29ddd47` FOREIGN KEY (`product_id`) REFERENCES `products` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=31 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `order_items`
--

LOCK TABLES `order_items` WRITE;
/*!40000 ALTER TABLE `order_items` DISABLE KEYS */;
INSERT INTO `order_items` VALUES (1,1,1,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(2,2,2,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(3,3,3,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(4,4,1,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(5,5,2,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(6,6,3,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(7,7,4,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(8,8,5,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(9,9,6,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(10,10,4,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(11,11,5,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(12,12,6,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(13,13,7,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(14,14,8,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(15,15,9,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(16,16,7,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(17,17,8,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(18,18,9,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(19,19,10,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(20,20,11,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(21,21,12,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(22,22,10,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(23,23,11,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(24,24,12,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(25,25,13,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(26,26,14,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(27,27,15,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(28,28,13,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(29,29,14,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(30,30,15,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000');
/*!40000 ALTER TABLE `order_items` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `orders`
--

DROP TABLE IF EXISTS `orders`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `orders` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `shop_id` bigint NOT NULL,
  `user_id` bigint NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_orders_on_shop_id` (`shop_id`),
  KEY `index_orders_on_user_id` (`user_id`),
  CONSTRAINT `fk_rails_7e761c2e1b` FOREIGN KEY (`shop_id`) REFERENCES `shops` (`id`),
  CONSTRAINT `fk_rails_f868b47f6a` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=31 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `orders`
--

LOCK TABLES `orders` WRITE;
/*!40000 ALTER TABLE `orders` DISABLE KEYS */;
INSERT INTO `orders` VALUES (1,1,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(2,1,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(3,1,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(4,1,2,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(5,1,2,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(6,1,2,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(7,2,3,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(8,2,3,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(9,2,3,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(10,2,4,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(11,2,4,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(12,2,4,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(13,3,5,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(14,3,5,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(15,3,5,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(16,3,6,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(17,3,6,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(18,3,6,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(19,4,7,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(20,4,7,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(21,4,7,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(22,4,8,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(23,4,8,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(24,4,8,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(25,5,9,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(26,5,9,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(27,5,9,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(28,5,10,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(29,5,10,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(30,5,10,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000');
/*!40000 ALTER TABLE `orders` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `products`
--

DROP TABLE IF EXISTS `products`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `products` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `price` decimal(10,2) NOT NULL,
  `shop_id` bigint NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_products_on_shop_id` (`shop_id`),
  CONSTRAINT `fk_rails_b169a26347` FOREIGN KEY (`shop_id`) REFERENCES `shops` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=16 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `products`
--

LOCK TABLES `products` WRITE;
/*!40000 ALTER TABLE `products` DISABLE KEYS */;
INSERT INTO `products` VALUES (1,'Product 1',10.00,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(2,'Product 2',20.00,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(3,'Product 3',30.00,1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(4,'Product 1',10.00,2,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(5,'Product 2',20.00,2,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(6,'Product 3',30.00,2,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(7,'Product 1',10.00,3,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(8,'Product 2',20.00,3,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(9,'Product 3',30.00,3,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(10,'Product 1',10.00,4,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(11,'Product 2',20.00,4,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(12,'Product 3',30.00,4,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(13,'Product 1',10.00,5,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(14,'Product 2',20.00,5,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(15,'Product 3',30.00,5,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000');
/*!40000 ALTER TABLE `products` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `reviews`
--

DROP TABLE IF EXISTS `reviews`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `reviews` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `reviewable_type` varchar(255) NOT NULL,
  `reviewable_id` bigint NOT NULL,
  `user_id` bigint NOT NULL,
  `rating` int NOT NULL,
  `content` text NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_reviews_on_reviewable` (`reviewable_type`,`reviewable_id`),
  KEY `index_reviews_on_user_id` (`user_id`),
  CONSTRAINT `fk_rails_74a66bd6c5` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `reviews`
--

LOCK TABLES `reviews` WRITE;
/*!40000 ALTER TABLE `reviews` DISABLE KEYS */;
/*!40000 ALTER TABLE `reviews` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `schema_migrations`
--

DROP TABLE IF EXISTS `schema_migrations`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `schema_migrations` (
  `version` varchar(255) NOT NULL,
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `schema_migrations`
--

LOCK TABLES `schema_migrations` WRITE;
/*!40000 ALTER TABLE `schema_migrations` DISABLE KEYS */;
/*!40000 ALTER TABLE `schema_migrations` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `shops`
--

DROP TABLE IF EXISTS `shops`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `shops` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `shops`
--

LOCK TABLES `shops` WRITE;
/*!40000 ALTER TABLE `shops` DISABLE KEYS */;
INSERT INTO `shops` VALUES (1,'Shop 1','2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(2,'Shop 2','2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(3,'Shop 3','2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(4,'Shop 4','2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(5,'Shop 5','2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000');
/*!40000 ALTER TABLE `shops` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `system_announcements`
--

DROP TABLE IF EXISTS `system_announcements`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `system_announcements` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `title` varchar(255) NOT NULL,
  `content` text NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=4 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `system_announcements`
--

LOCK TABLES `system_announcements` WRITE;
/*!40000 ALTER TABLE `system_announcements` DISABLE KEYS */;
INSERT INTO `system_announcements` VALUES (1,'Announcement 1','This is the content of announcement 1.','2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(2,'Announcement 2','This is the content of announcement 2.','2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(3,'Announcement 3','This is the content of announcement 3.','2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000');
/*!40000 ALTER TABLE `system_announcements` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `transactions`
--

DROP TABLE IF EXISTS `transactions`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `transactions` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `order_id` bigint NOT NULL,
  `type` varchar(255) NOT NULL,
  `amount` decimal(10,2) NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_transactions_on_order_id` (`order_id`),
  CONSTRAINT `fk_rails_59d791a33f` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=31 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `transactions`
--

LOCK TABLES `transactions` WRITE;
/*!40000 ALTER TABLE `transactions` DISABLE KEYS */;
INSERT INTO `transactions` VALUES (1,1,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(2,2,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(3,3,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(4,4,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(5,5,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(6,6,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(7,7,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(8,8,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(9,9,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(10,10,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(11,11,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(12,12,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(13,13,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(14,14,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(15,15,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(16,16,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(17,17,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(18,18,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(19,19,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(20,20,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(21,21,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(22,22,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(23,23,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(24,24,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(25,25,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(26,26,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(27,27,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(28,28,'PaymentTransaction',10.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(29,29,'PaymentTransaction',20.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(30,30,'PaymentTransaction',30.00,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000');
/*!40000 ALTER TABLE `transactions` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `users`
--

DROP TABLE IF EXISTS `users`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `users` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `email` varchar(255) NOT NULL,
  `shop_id` bigint NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_users_on_shop_id` (`shop_id`),
  CONSTRAINT `fk_rails_a622b365a2` FOREIGN KEY (`shop_id`) REFERENCES `shops` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=11 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `users`
--

LOCK TABLES `users` WRITE;
/*!40000 ALTER TABLE `users` DISABLE KEYS */;
INSERT INTO `users` VALUES (1,'User 1','user1@example.com',1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(2,'User 2','user2@example.com',1,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(3,'User 1','user1@example.com',2,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(4,'User 2','user2@example.com',2,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(5,'User 1','user1@example.com',3,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(6,'User 2','user2@example.com',3,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(7,'User 1','user1@example.com',4,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(8,'User 2','user2@example.com',4,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(9,'User 1','user1@example.com',5,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000'),(10,'User 2','user2@example.com',5,'2025-01-01 00:00:00.000000','2025-01-01 00:00:00.000000');
/*!40000 ALTER TABLE `users` ENABLE KEYS */;
UNLOCK TABLES;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2025-02-11  5:56:25
