-- ===============================
-- 공통 계정 초기화 스크립트
-- 마스터 MySQL 노드(mysql1,3)에 동일하게 적용
-- ===============================

-- =================================
-- 1. ProxySQL 모니터링 유저
-- =================================
CREATE USER 'proxysql_monitor'@'%' IDENTIFIED BY 'monitor1234!';

GRANT all privileges ON *.* TO 'proxysql_monitor'@'%';



-- =================================
-- 2. Orchestrator 관리 유저
-- =================================
CREATE USER 'orc_topology_user'@'%' 
  IDENTIFIED WITH mysql_native_password BY 'orc1234!';

GRANT all privileges ON *.* TO 'orc_topology_user'@'%';
  

-- =================================
-- 3. 복제용 유저
--    (실제로는 "마스터에서만" 필요하지만,
--     편하게 모든 노드에 만들어놔도 문제 없음)
-- =================================
CREATE USER 'repl_user'@'%' IDENTIFIED BY 'repl1234!';

GRANT all privileges ON *.* TO 'repl_user'@'%';


FLUSH PRIVILEGES;