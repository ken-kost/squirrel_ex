-- List a post's id, title and (nullable) body by author.
select id, title, body? from posts where author_id = $1 order by title
