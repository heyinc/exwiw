--
-- PostgreSQL database dump
--

\restrict SsVj6CQKSuMz5uao6sWVIKu5yURMy2dkTgEin5LcfUDOCsG5R3eOaORdNb7IMEB

-- Dumped from database version 17.10
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: user_role; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.user_role AS ENUM (
    'admin',
    'member'
);


ALTER TYPE public.user_role OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.ar_internal_metadata OWNER TO postgres;

--
-- Name: order_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_items (
    id bigint NOT NULL,
    order_id bigint NOT NULL,
    product_id bigint NOT NULL,
    quantity integer DEFAULT 1 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.order_items OWNER TO postgres;

--
-- Name: order_items_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.order_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.order_items_id_seq OWNER TO postgres;

--
-- Name: order_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.order_items_id_seq OWNED BY public.order_items.id;


--
-- Name: orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.orders (
    id bigint NOT NULL,
    shop_id bigint NOT NULL,
    user_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.orders OWNER TO postgres;

--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.orders_id_seq OWNER TO postgres;

--
-- Name: orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    name character varying NOT NULL,
    price numeric(10,2) NOT NULL,
    shop_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.products OWNER TO postgres;

--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.products_id_seq OWNER TO postgres;

--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.reviews (
    id bigint NOT NULL,
    reviewable_type character varying NOT NULL,
    reviewable_id bigint NOT NULL,
    user_id bigint NOT NULL,
    rating integer NOT NULL,
    content text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.reviews OWNER TO postgres;

--
-- Name: reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.reviews_id_seq OWNER TO postgres;

--
-- Name: reviews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.reviews_id_seq OWNED BY public.reviews.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


ALTER TABLE public.schema_migrations OWNER TO postgres;

--
-- Name: shops; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.shops (
    id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.shops OWNER TO postgres;

--
-- Name: shops_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.shops_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.shops_id_seq OWNER TO postgres;

--
-- Name: shops_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.shops_id_seq OWNED BY public.shops.id;


--
-- Name: system_announcements; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.system_announcements (
    id bigint NOT NULL,
    title character varying NOT NULL,
    content text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.system_announcements OWNER TO postgres;

--
-- Name: system_announcements_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.system_announcements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.system_announcements_id_seq OWNER TO postgres;

--
-- Name: system_announcements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.system_announcements_id_seq OWNED BY public.system_announcements.id;


--
-- Name: transactions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.transactions (
    id bigint NOT NULL,
    order_id bigint NOT NULL,
    type character varying NOT NULL,
    amount numeric(10,2) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.transactions OWNER TO postgres;

--
-- Name: transactions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.transactions_id_seq OWNER TO postgres;

--
-- Name: transactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.transactions_id_seq OWNED BY public.transactions.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    name character varying NOT NULL,
    email character varying NOT NULL,
    shop_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    role public.user_role
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_id_seq OWNER TO postgres;

--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: order_items id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_items ALTER COLUMN id SET DEFAULT nextval('public.order_items_id_seq'::regclass);


--
-- Name: orders id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: reviews id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reviews ALTER COLUMN id SET DEFAULT nextval('public.reviews_id_seq'::regclass);


--
-- Name: shops id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shops ALTER COLUMN id SET DEFAULT nextval('public.shops_id_seq'::regclass);


--
-- Name: system_announcements id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.system_announcements ALTER COLUMN id SET DEFAULT nextval('public.system_announcements_id_seq'::regclass);


--
-- Name: transactions id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions ALTER COLUMN id SET DEFAULT nextval('public.transactions_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Data for Name: ar_internal_metadata; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ar_internal_metadata (key, value, created_at, updated_at) FROM stdin;
environment	default_env	2026-05-26 10:00:43.498033	2026-05-26 10:00:43.498035
\.


--
-- Data for Name: order_items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.order_items (id, order_id, product_id, quantity, created_at, updated_at) FROM stdin;
1	1	1	1	2025-01-01 00:00:00	2025-01-01 00:00:00
2	2	2	1	2025-01-01 00:00:00	2025-01-01 00:00:00
3	3	3	1	2025-01-01 00:00:00	2025-01-01 00:00:00
4	4	1	1	2025-01-01 00:00:00	2025-01-01 00:00:00
5	5	2	1	2025-01-01 00:00:00	2025-01-01 00:00:00
6	6	3	1	2025-01-01 00:00:00	2025-01-01 00:00:00
7	7	4	1	2025-01-01 00:00:00	2025-01-01 00:00:00
8	8	5	1	2025-01-01 00:00:00	2025-01-01 00:00:00
9	9	6	1	2025-01-01 00:00:00	2025-01-01 00:00:00
10	10	4	1	2025-01-01 00:00:00	2025-01-01 00:00:00
11	11	5	1	2025-01-01 00:00:00	2025-01-01 00:00:00
12	12	6	1	2025-01-01 00:00:00	2025-01-01 00:00:00
13	13	7	1	2025-01-01 00:00:00	2025-01-01 00:00:00
14	14	8	1	2025-01-01 00:00:00	2025-01-01 00:00:00
15	15	9	1	2025-01-01 00:00:00	2025-01-01 00:00:00
16	16	7	1	2025-01-01 00:00:00	2025-01-01 00:00:00
17	17	8	1	2025-01-01 00:00:00	2025-01-01 00:00:00
18	18	9	1	2025-01-01 00:00:00	2025-01-01 00:00:00
19	19	10	1	2025-01-01 00:00:00	2025-01-01 00:00:00
20	20	11	1	2025-01-01 00:00:00	2025-01-01 00:00:00
21	21	12	1	2025-01-01 00:00:00	2025-01-01 00:00:00
22	22	10	1	2025-01-01 00:00:00	2025-01-01 00:00:00
23	23	11	1	2025-01-01 00:00:00	2025-01-01 00:00:00
24	24	12	1	2025-01-01 00:00:00	2025-01-01 00:00:00
25	25	13	1	2025-01-01 00:00:00	2025-01-01 00:00:00
26	26	14	1	2025-01-01 00:00:00	2025-01-01 00:00:00
27	27	15	1	2025-01-01 00:00:00	2025-01-01 00:00:00
28	28	13	1	2025-01-01 00:00:00	2025-01-01 00:00:00
29	29	14	1	2025-01-01 00:00:00	2025-01-01 00:00:00
30	30	15	1	2025-01-01 00:00:00	2025-01-01 00:00:00
\.


--
-- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.orders (id, shop_id, user_id, created_at, updated_at) FROM stdin;
1	1	1	2025-01-01 00:00:00	2025-01-01 00:00:00
2	1	1	2025-01-01 00:00:00	2025-01-01 00:00:00
3	1	1	2025-01-01 00:00:00	2025-01-01 00:00:00
4	1	2	2025-01-01 00:00:00	2025-01-01 00:00:00
5	1	2	2025-01-01 00:00:00	2025-01-01 00:00:00
6	1	2	2025-01-01 00:00:00	2025-01-01 00:00:00
7	2	3	2025-01-01 00:00:00	2025-01-01 00:00:00
8	2	3	2025-01-01 00:00:00	2025-01-01 00:00:00
9	2	3	2025-01-01 00:00:00	2025-01-01 00:00:00
10	2	4	2025-01-01 00:00:00	2025-01-01 00:00:00
11	2	4	2025-01-01 00:00:00	2025-01-01 00:00:00
12	2	4	2025-01-01 00:00:00	2025-01-01 00:00:00
13	3	5	2025-01-01 00:00:00	2025-01-01 00:00:00
14	3	5	2025-01-01 00:00:00	2025-01-01 00:00:00
15	3	5	2025-01-01 00:00:00	2025-01-01 00:00:00
16	3	6	2025-01-01 00:00:00	2025-01-01 00:00:00
17	3	6	2025-01-01 00:00:00	2025-01-01 00:00:00
18	3	6	2025-01-01 00:00:00	2025-01-01 00:00:00
19	4	7	2025-01-01 00:00:00	2025-01-01 00:00:00
20	4	7	2025-01-01 00:00:00	2025-01-01 00:00:00
21	4	7	2025-01-01 00:00:00	2025-01-01 00:00:00
22	4	8	2025-01-01 00:00:00	2025-01-01 00:00:00
23	4	8	2025-01-01 00:00:00	2025-01-01 00:00:00
24	4	8	2025-01-01 00:00:00	2025-01-01 00:00:00
25	5	9	2025-01-01 00:00:00	2025-01-01 00:00:00
26	5	9	2025-01-01 00:00:00	2025-01-01 00:00:00
27	5	9	2025-01-01 00:00:00	2025-01-01 00:00:00
28	5	10	2025-01-01 00:00:00	2025-01-01 00:00:00
29	5	10	2025-01-01 00:00:00	2025-01-01 00:00:00
30	5	10	2025-01-01 00:00:00	2025-01-01 00:00:00
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.products (id, name, price, shop_id, created_at, updated_at) FROM stdin;
1	Product 1	10.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
2	Product 2	20.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
3	Product 3	30.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
4	Product 1	10.00	2	2025-01-01 00:00:00	2025-01-01 00:00:00
5	Product 2	20.00	2	2025-01-01 00:00:00	2025-01-01 00:00:00
6	Product 3	30.00	2	2025-01-01 00:00:00	2025-01-01 00:00:00
7	Product 1	10.00	3	2025-01-01 00:00:00	2025-01-01 00:00:00
8	Product 2	20.00	3	2025-01-01 00:00:00	2025-01-01 00:00:00
9	Product 3	30.00	3	2025-01-01 00:00:00	2025-01-01 00:00:00
10	Product 1	10.00	4	2025-01-01 00:00:00	2025-01-01 00:00:00
11	Product 2	20.00	4	2025-01-01 00:00:00	2025-01-01 00:00:00
12	Product 3	30.00	4	2025-01-01 00:00:00	2025-01-01 00:00:00
13	Product 1	10.00	5	2025-01-01 00:00:00	2025-01-01 00:00:00
14	Product 2	20.00	5	2025-01-01 00:00:00	2025-01-01 00:00:00
15	Product 3	30.00	5	2025-01-01 00:00:00	2025-01-01 00:00:00
\.


--
-- Data for Name: reviews; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.reviews (id, reviewable_type, reviewable_id, user_id, rating, content, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: schema_migrations; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.schema_migrations (version) FROM stdin;
\.


--
-- Data for Name: shops; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.shops (id, name, created_at, updated_at) FROM stdin;
1	Shop 1	2025-01-01 00:00:00	2025-01-01 00:00:00
2	Shop 2	2025-01-01 00:00:00	2025-01-01 00:00:00
3	Shop 3	2025-01-01 00:00:00	2025-01-01 00:00:00
4	Shop 4	2025-01-01 00:00:00	2025-01-01 00:00:00
5	Shop 5	2025-01-01 00:00:00	2025-01-01 00:00:00
\.


--
-- Data for Name: system_announcements; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.system_announcements (id, title, content, created_at, updated_at) FROM stdin;
1	Announcement 1	This is the content of announcement 1.	2025-01-01 00:00:00	2025-01-01 00:00:00
2	Announcement 2	This is the content of announcement 2.	2025-01-01 00:00:00	2025-01-01 00:00:00
3	Announcement 3	This is the content of announcement 3.	2025-01-01 00:00:00	2025-01-01 00:00:00
\.


--
-- Data for Name: transactions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.transactions (id, order_id, type, amount, created_at, updated_at) FROM stdin;
1	1	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
2	2	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
3	3	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
4	4	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
5	5	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
6	6	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
7	7	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
8	8	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
9	9	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
10	10	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
11	11	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
12	12	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
13	13	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
14	14	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
15	15	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
16	16	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
17	17	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
18	18	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
19	19	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
20	20	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
21	21	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
22	22	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
23	23	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
24	24	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
25	25	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
26	26	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
27	27	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
28	28	PaymentTransaction	10.00	2025-01-01 00:00:00	2025-01-01 00:00:00
29	29	PaymentTransaction	20.00	2025-01-01 00:00:00	2025-01-01 00:00:00
30	30	PaymentTransaction	30.00	2025-01-01 00:00:00	2025-01-01 00:00:00
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (id, name, email, shop_id, created_at, updated_at, role) FROM stdin;
1	User 1	user1@example.com	1	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
2	User 2	user2@example.com	1	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
3	User 1	user1@example.com	2	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
4	User 2	user2@example.com	2	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
5	User 1	user1@example.com	3	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
6	User 2	user2@example.com	3	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
7	User 1	user1@example.com	4	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
8	User 2	user2@example.com	4	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
9	User 1	user1@example.com	5	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
10	User 2	user2@example.com	5	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
\.


--
-- Name: order_items_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.order_items_id_seq', 30, true);


--
-- Name: orders_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.orders_id_seq', 30, true);


--
-- Name: products_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.products_id_seq', 15, true);


--
-- Name: reviews_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.reviews_id_seq', 1, false);


--
-- Name: shops_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.shops_id_seq', 5, true);


--
-- Name: system_announcements_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.system_announcements_id_seq', 3, true);


--
-- Name: transactions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.transactions_id_seq', 30, true);


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.users_id_seq', 10, true);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: shops shops_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shops
    ADD CONSTRAINT shops_pkey PRIMARY KEY (id);


--
-- Name: system_announcements system_announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.system_announcements
    ADD CONSTRAINT system_announcements_pkey PRIMARY KEY (id);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: index_order_items_on_order_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_order_items_on_order_id ON public.order_items USING btree (order_id);


--
-- Name: index_order_items_on_product_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_order_items_on_product_id ON public.order_items USING btree (product_id);


--
-- Name: index_orders_on_shop_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_orders_on_shop_id ON public.orders USING btree (shop_id);


--
-- Name: index_orders_on_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_orders_on_user_id ON public.orders USING btree (user_id);


--
-- Name: index_products_on_shop_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_products_on_shop_id ON public.products USING btree (shop_id);


--
-- Name: index_reviews_on_reviewable; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_reviews_on_reviewable ON public.reviews USING btree (reviewable_type, reviewable_id);


--
-- Name: index_reviews_on_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_reviews_on_user_id ON public.reviews USING btree (user_id);


--
-- Name: index_transactions_on_order_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_transactions_on_order_id ON public.transactions USING btree (order_id);


--
-- Name: index_users_on_shop_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX index_users_on_shop_id ON public.users USING btree (shop_id);


--
-- Name: transactions fk_rails_59d791a33f; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT fk_rails_59d791a33f FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: reviews fk_rails_74a66bd6c5; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_74a66bd6c5 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: orders fk_rails_7e761c2e1b; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_7e761c2e1b FOREIGN KEY (shop_id) REFERENCES public.shops(id);


--
-- Name: users fk_rails_a622b365a2; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_a622b365a2 FOREIGN KEY (shop_id) REFERENCES public.shops(id);


--
-- Name: products fk_rails_b169a26347; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_rails_b169a26347 FOREIGN KEY (shop_id) REFERENCES public.shops(id);


--
-- Name: order_items fk_rails_e3cb28f071; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT fk_rails_e3cb28f071 FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: order_items fk_rails_f1a29ddd47; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT fk_rails_f1a29ddd47 FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: orders fk_rails_f868b47f6a; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_f868b47f6a FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

\unrestrict SsVj6CQKSuMz5uao6sWVIKu5yURMy2dkTgEin5LcfUDOCsG5R3eOaORdNb7IMEB

