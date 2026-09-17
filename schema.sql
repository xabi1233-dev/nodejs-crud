-- Run this once as a MySQL admin user:
--   sudo mysql < /var/www/your_domain/crud/schema.sql

CREATE DATABASE IF NOT EXISTS crud_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'crud_user'@'localhost' IDENTIFIED BY 'CHANGE_ME_StrongPass#1';
GRANT ALL PRIVILEGES ON crud_db.* TO 'crud_user'@'localhost';
FLUSH PRIVILEGES;

USE crud_db;

CREATE TABLE IF NOT EXISTS users (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name       VARCHAR(100) NOT NULL,
  email      VARCHAR(190) NOT NULL,
  phone      VARCHAR(30)  DEFAULT NULL,
  status     ENUM('active','inactive') NOT NULL DEFAULT 'active',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uniq_users_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO users (name, email, phone, status) VALUES
  ('Ada Lovelace',  'ada@example.com',    '+1-555-0100', 'active'),
  ('Alan Turing',   'alan@example.com',   '+1-555-0101', 'active'),
  ('Grace Hopper',  'grace@example.com',  '+1-555-0102', 'inactive');
