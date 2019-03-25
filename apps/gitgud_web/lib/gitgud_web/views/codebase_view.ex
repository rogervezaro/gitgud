defmodule GitGud.Web.CodebaseView do
  @moduledoc false
  use GitGud.Web, :view

  alias GitRekt.Git

  alias GitGud.User
  alias GitGud.UserQuery

  alias GitGud.GitBlob
  alias GitGud.GitCommit
  alias GitGud.GitDiff
  alias GitGud.GitReference
  alias GitGud.GitTag
  alias GitGud.GitTree
  alias GitGud.GitTreeEntry

  alias Phoenix.Param

  import Phoenix.HTML.Link
  import Phoenix.HTML.Tag

  import GitRekt.Git, only: [oid_fmt: 1, oid_fmt_short: 1]

  @external_resource highlight_languages = Path.join(:code.priv_dir(:gitgud_web), "highlight-languages.txt")

  @spec batch_branches_commits_authors(Enumerable.t) :: [{GitReference.t, {GitCommit.t, User.t | map}}]
  def batch_branches_commits_authors(references_commits) do
    {references, commits} = Enum.unzip(references_commits)
    commits_authors = batch_commits_authors(commits)
    Enum.zip(references, commits_authors)
  end

  @spec batch_tags_commits_authors(Enumerable.t) :: [{GitReference.t | GitTag.t, {GitCommit.t, User.t | map}}]
  def batch_tags_commits_authors(tags_commits) do
    {tags, commits} = Enum.unzip(tags_commits)
    authors = Enum.map(tags_commits, &fetch_author/1)
    users = query_users(authors)
    Enum.zip(tags, Enum.map(Enum.zip(commits, authors), &zip_author(&1, users)))
  end

  @spec batch_commits_authors(Enumerable.t) :: [{GitCommit.t, User.t | map}]
  def batch_commits_authors(commits) do
    authors = Enum.map(commits, &fetch_author/1)
    users = query_users(authors)
    Enum.map(Enum.zip(commits, authors), &zip_author(&1, users))
  end

  @spec sort_by_commit_timestamp(Enumerable.t) :: [{GitReference.t | GitTag.t, GitCommit.t}]
  def sort_by_commit_timestamp(references_or_tags) do
    commits = Enum.map(references_or_tags, &fetch_commit/1)
    Enum.sort_by(Enum.zip(references_or_tags, commits), &commit_timestamp(elem(&1, 1)), &compare_timestamps/2)
  end

  @spec branch_select(Plug.Conn.t) :: binary
  def branch_select(conn) do
    %{repo: repo, revision: revision} = Map.take(conn.assigns, [:repo, :revision])
    react_component("BranchSelect", [
      repo: to_relay_id(repo),
      oid: revision_oid(revision),
      name: revision_name(revision),
      type: to_string(revision_type(revision))], class: "branch-select")
  end

  @spec repo_clone(Plug.Conn.t) :: binary
  def repo_clone(conn) do
    repo = Map.get(conn.assigns, :repo)
    props = [http: Routes.codebase_url(conn, :show, repo.owner, repo)]
    props = if user = current_user(conn),
        do: [ssh: "#{user.login}@#{GitGud.Web.Endpoint.struct_url().host}:#{repo.owner.login}/#{repo.name}"] ++ props,
      else: props
    react_component("RepoClone", props, class: "repo-clone")
  end

  @spec blob_content(GitBlob.t) :: binary | nil
  def blob_content(%GitBlob{} = blob) do
    case GitBlob.content(blob) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end

  @spec blob_size(GitBlob.t) :: non_neg_integer | nil
  def blob_size(%GitBlob{} = blob) do
    case GitBlob.size(blob) do
      {:ok, size} -> size
      {:error, _reason} -> nil
    end
  end

  @spec blob_table(binary, GitBlob.t) :: binary
  def blob_table(file_path, blob) do
    highlight_lang = highlight_language_from_path(file_path)
    content_tag(:table, [class: "blob-table"], do: [
      content_tag(:tbody, do:
        for {line_content, line_no} <- Enum.with_index(String.split(blob_content(blob), "\n"), 1) do
          content_tag(:tr, do: [
            content_tag(:td, line_no, class: "line-no", colspan: 2),
            content_tag(:td, [class: "code"], do: [
              content_tag(:div, line_content, class: Enum.join(["code-inner", highlight_lang], " "))
            ])
          ])
        end
      )
    ])
  end

  @spec commit_author(GitCommit.t) :: map | nil
  def commit_author(%GitCommit{} = commit) do
    case GitCommit.author(commit) do
      {:ok, author} ->
        if user = UserQuery.by_email(author.email, preload: :primary_email),
          do: user,
        else: author
      {:error, _reason} -> nil
    end
  end

  @spec commit_timestamp(GitCommit.t) :: DateTime.t | nil
  def commit_timestamp(%GitCommit{} = commit) do
    case GitCommit.timestamp(commit) do
      {:ok, timestamp} -> timestamp
      {:error, _reason} -> nil
    end
  end

  @spec commit_message(GitCommit.t) :: binary | nil
  def commit_message(%GitCommit{} = commit) do
    case GitCommit.message(commit) do
      {:ok, message} -> message
      {:error, _reason} -> nil
    end
  end

  @spec commit_message_title(GitCommit.t) :: binary | nil
  def commit_message_title(%GitCommit{} = commit) do
    case GitCommit.message(commit) do
      {:ok, message} -> hd(String.split(message, "\n", parts: 2))
      {:error, _reason} -> nil
    end
  end

  @spec revision_oid(Repo.git_object) :: binary
  def revision_oid(%{oid: oid} = _object), do: oid_fmt(oid)

  @spec revision_name(Repo.git_object) :: binary
  def revision_name(%GitCommit{oid: oid} = _object), do: oid_fmt_short(oid)
  def revision_name(%GitTag{name: name} = _object), do: name
  def revision_name(%GitReference{name: name} = _object), do: name

  @spec revision_type(Repo.git_object) :: atom
  def revision_type(%GitCommit{} = _object), do: :commit
  def revision_type(%GitTag{} = _object), do: :tag
  def revision_type(%GitReference{} = ref), do: ref.type

  @spec tree_entries(GitTree.t) :: [GitTreeEntry.t]
  def tree_entries(%GitTree{} = tree) do
    case GitTree.entries(tree) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  @spec tree_readme(GitTree.t) :: binary | nil
  def tree_readme(%GitTree{} = tree) do
    with {:ok, entry} <- GitTree.by_path(tree, "README.md"),
         {:ok, blob} <- GitTreeEntry.target(entry),
         {:ok, content} <- GitBlob.content(blob),
         {:ok, html, []} <- Earmark.as_html(content) do
      html
    else
      {:error, _reason} -> nil
    end
  end

  @spec diff_stats(GitDiff.t) :: map | nil
  def diff_stats(%GitDiff{} = diff) do
    case GitDiff.stats(diff) do
      {:ok, stats} -> stats
      {:error, _reason} -> nil
    end
  end

  @spec diff_deltas(GitDiff.t) :: [map] | nil
  def diff_deltas(%GitDiff{} = diff) do
    case GitDiff.deltas(diff) do
      {:ok, deltas} -> deltas
      {:error, _reason} -> nil
    end
  end

  @spec diff_deltas_with_comments(GitCommit.t, GitDiff.t) :: [map] | nil
  def diff_deltas_with_comments(commit, diff) do
    commit_reviews = GitCommit.reviews(commit)
    Enum.map(diff_deltas(diff), fn delta ->
      reviews = Enum.filter(commit_reviews, &(&1.blob_oid in [delta.old_file.oid, delta.new_file.oid]))
      Enum.reduce(reviews, delta, fn review, delta ->
        update_in(delta.hunks, fn hunks ->
          List.update_at(hunks, review.hunk, &attach_comments_to_delta_line(&1, review.line, review.comments))
        end)
      end)
    end)
  end

  @spec diff_table(Plug.Conn.t, binary, [map]) :: binary
  def diff_table(conn, file_path, delta) do
    highlight_lang = highlight_language_from_path(file_path)
    commit_oid = Git.oid_fmt(conn.assigns.commit.oid)
    blob_oid = Git.oid_fmt(delta.new_file.oid)
    content_tag(:table, [class: "blob-table diff-table", data_commit: commit_oid, data_blob: blob_oid], do: [
      content_tag(:tbody, do:
        for {hunk, hunk_index} <- Enum.with_index(delta.hunks) do
          [
            content_tag(:tr, [class: "hunk"], do: [
              content_tag(:td, "", class: "line-no", colspan: 2),
              content_tag(:td, [class: "code", colspan: 2], do: [
                content_tag(:div, hunk.header, class: "code-inner nohighlight")
              ])
            ]),
            for {line, line_index} <- Enum.with_index(hunk.lines) do
              line_class =
                cond do
                  line.origin == "+" -> "diff-addition"
                  line.origin == "-" -> "diff-deletion"
                  true -> ""
                end
              line_html = content_tag(:tr, [class: line_class], do: [
                (if line.old_line_no != -1,
                  do: content_tag(:td, line.old_line_no, class: "line-no"),
                else: content_tag(:td, "", class: "line-no")),
                (if line.new_line_no != -1,
                  do: content_tag(:td, line.new_line_no, class: "line-no"),
                else: content_tag(:td, "", class: "line-no")),
                  content_tag(:td, [class: "code origin"], do: [
                    content_tag(:button, [class: "button is-link is-small", data_hunk: hunk_index, data_line: line_index], do: [
                      content_tag(:span, [class: "icon"], do: [
                        content_tag(:i, "", [class: "fa fa-comment-alt"])
                      ])
                    ]),
                    line.origin
                  ]),
                content_tag(:td, [class: "code"], do: [
                  content_tag(:div, line.content, class: Enum.join(["code-inner", highlight_lang], " "))
                ])
              ])
              if comments = Map.get(line, :comments) do
                [
                  line_html,
                  content_tag(:tr, [class: "inline-comments"], do: [
                    content_tag(:td, [colspan: 4], do: [
                      for comment <- comments do
                        content_tag(:div, [class: "box"], do: [
                          link(comment.author, to: Routes.user_path(conn, :show, comment.author), class: "has-text-black"),
                          "\n",
                          datetime_format(comment.inserted_at, "{relative}"),
                          content_tag(:div, [class: "content"], do: [
                            content_tag(:p, comment.body)
                          ])
                        ])
                      end,
                      (if authenticated?(conn),
                        do: react_component("InlineCommentForm", [commit: commit_oid, blob: blob_oid, hunk: hunk_index, line: line_index, reply: true], class: "inline-comment-form"),
                      else: [])
                    ])
                  ])
                ]
              end || line_html
            end
          ]
        end
      )
    ])
  end

  @spec breadcrump_action(atom) :: atom
  def breadcrump_action(:blob), do: :tree
  def breadcrump_action(action), do: action

  @spec title(atom, map) :: binary
  def title(:show, %{repo: repo}) do
    if desc = repo.description,
      do: "#{repo.owner.login}/#{repo.name}: #{desc}",
    else: "#{repo.owner.login}/#{repo.name}"
  end

  def title(:branches, %{repo: repo}), do: "Branches · #{repo.owner.login}/#{repo.name}"
  def title(:tags, %{repo: repo}), do: "Tags · #{repo.owner.login}/#{repo.name}"
  def title(:commit, %{repo: repo, commit: commit}), do: "#{commit_message_title(commit)} · #{repo.owner.login}/#{repo.name}@#{oid_fmt_short(commit.oid)}"
  def title(:tree, %{repo: repo, revision: rev, tree_path: []}), do: "#{Param.to_param(rev)} · #{repo.owner.login}/#{repo.name}"
  def title(:tree, %{repo: repo, revision: rev, tree_path: path}), do: "#{Path.join(path)} at #{Param.to_param(rev)} · #{repo.owner.login}/#{repo.name}"
  def title(:blob, %{repo: repo, revision: rev, tree_path: path}), do: "#{Path.join(path)} at #{Param.to_param(rev)} · #{repo.owner.login}/#{repo.name}"
  def title(:history, %{repo: repo, revision: rev, tree_path: []}), do: "Commits at #{Param.to_param(rev)} · #{repo.owner.login}/#{repo.name}"
  def title(:history, %{repo: repo, revision: rev, tree_path: path}), do: "Commits at #{Param.to_param(rev)} · #{repo.owner.login}/#{repo.name}/#{Path.join(path)}"

  #
  # Helpers
  #

  defp fetch_commit(%GitReference{} = reference) do
    case GitReference.target(reference, :commit) do
      {:ok, commit} -> commit
      {:error, _reason} -> nil
    end
  end

  defp fetch_commit(%GitTag{} = tag) do
    case GitTag.target(tag) do
      {:ok, commit} -> commit
      {:error, _reason} -> nil
    end
  end

  defp fetch_author(%GitReference{} = reference) do
    case GitReference.target(reference, :commit) do
      {:ok, commit} ->
        fetch_author(commit)
      {:error, _reason} -> nil
    end
  end

  defp fetch_author(%GitCommit{} = commit) do
    case GitCommit.author(commit) do
      {:ok, sig} -> sig
      {:error, _reason} -> nil
    end
  end

  defp fetch_author(%GitTag{} = tag) do
    case GitTag.author(tag) do
      {:ok, sig} -> sig
      {:error, _reason} -> nil
    end
  end

  defp fetch_author({%GitReference{} = _reference, %GitCommit{} = commit}) do
    fetch_author(commit)
  end

  defp fetch_author({%GitTag{} = tag, %GitCommit{} = _commit}) do
    fetch_author(tag)
  end

  defp query_users(authors) do
    authors
    |> Enum.map(&(&1.email))
    |> Enum.uniq()
    |> UserQuery.by_email(preload: [:primary_email, :emails])
    |> Enum.flat_map(&flatten_user_emails/1)
    |> Map.new()
  end

  defp flatten_user_emails(user) do
    Enum.map(user.emails, &{&1.address, user})
  end

  defp highlight_language_from_path(path) do
    highlight_language(Path.extname(path))
  end

  for line <- File.stream!(highlight_languages) do
    [language|extensions] = String.split(String.trim(line), ~r/\s/, trim: true)
    for extension <- extensions do
      defp highlight_language("." <> unquote(extension)), do: unquote(language)
    end
  end

  defp highlight_language(_extension), do: "nohighlight"

  defp compare_timestamps(one, two) do
    case DateTime.compare(one, two) do
      :gt -> true
      :eq -> false
      :lt -> false
    end
  end

  defp attach_comments_to_delta_line(hunk, line, comments) do
    update_in(hunk.lines, fn lines ->
      List.update_at(lines, line, &Map.put(&1, :comments, comments))
    end)
  end

  defp zip_author({parent, author}, users) do
    {parent, Map.get(users, author.email, author)}
  end
end
