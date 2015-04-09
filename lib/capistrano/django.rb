after 'deploy:updating', 'python:create_virtualenv'

namespace :deploy do

  desc 'Restart application'
  task :restart do
    invoke 'deploy:nginx_restart'
  end

  task :nginx_restart do
    on roles(:web) do |h|
      within release_path do
        pid_file = "#{fetch(:supervisor_pid_file)}"
        if test "[ -e #{pid_file} ]"
          # kill old supervisor process, about to be replaced with new one
          execute "kill `cat #{pid_file}`"
        end
        
        # if supervisor isn't running, start it with the specified config file
        execute "venv/bin/supervisord", '-c=#{fetch(:supervisor_config_file)}'
      end
    end
  end

end

namespace :python do

  def virtualenv_path
    File.join(
      fetch(:shared_virtualenv) ? shared_path : release_path, "venv"
    )
  end

  desc "Create a python virtualenv"
  task :create_virtualenv do
    on roles(:all) do |h|
      execute "virtualenv #{virtualenv_path}"
      execute "#{virtualenv_path}/bin/pip install -r #{release_path}/#{fetch(:pip_requirements)}"
      if fetch(:shared_virtualenv)
        execute :ln, "-s", virtualenv_path, File.join(release_path, 'venv')
      end
    end

    invoke 'django:setup'
  end

end

namespace :django do

  def django(args, flags="", run_on=:all)
    on roles(run_on) do |h|
      manage_path = File.join(release_path, fetch(:django_project_dir) || '', 'manage.py')
      execute "#{release_path}/venv/bin/python #{manage_path} #{args} #{flags}"
    end
  end

  #after 'deploy:restart', 'django:restart_celery'

  desc "Setup Django environment"
  task :setup do
    if fetch(:django_compressor)
      invoke 'django:compress'
    end
    invoke 'django:compilemessages'
    invoke 'django:collectstatic'
    invoke 'django:symlink_settings'
    if !fetch(:nginx)
      invoke 'django:symlink_wsgi'
    end
    invoke 'django:migrate'
  end

  desc "Compile Messages"
  task :compilemessages do
    if fetch :compilemessages
      django("compilemessages")
    end
  end

  desc "Restart Celery"
  task :restart_celery do
    if fetch(:celery_name)
      invoke 'django:restart_celeryd'
      invoke 'django:restart_celerybeat'
    end
    if fetch(:celery_names)
      invoke 'django:restart_named_celery_processes'
    end
  end

  desc "Restart Celeryd"
  task :restart_celeryd do
    on roles(:jobs) do
      execute "sudo service celeryd-#{fetch(:celery_name)} restart"
    end
  end

  desc "Restart Celerybeat"
  task :restart_celerybeat do
    on roles(:jobs) do
      execute "sudo service celerybeat-#{fetch(:celery_name)} restart"
    end
  end

  desc "Restart named celery processes"
  task :restart_named_celery_processes do
    on roles(:jobs) do
      fetch(:celery_names).each { | celery_name, celery_beat |
        execute "sudo service celeryd-#{celery_name} restart"
        if celery_beat
          execute "sudo service celerybeat-#{celery_name} restart"
        end
      }
    end
  end

  desc "Run django-compressor"
  task :compress do
    django("compress")
  end

  desc "Run django's collectstatic"
  task :collectstatic do
    django("collectstatic", "-i *.coffee -i *.less -i node_modules/* -i bower_components/* --noinput")
  end

  desc "Symlink django settings to local_settings.py"
  task :symlink_settings do
    settings_path = File.join(release_path, fetch(:django_settings_dir))
    on roles(:all) do
      execute "ln -s #{settings_path}/#{fetch(:django_settings)}.py #{fetch(:django_project_dir)}/local_settings.py"
    end
  end

  desc "Symlink wsgi script to live.wsgi"
  task :symlink_wsgi do
    on roles(:web) do
      wsgi_path = File.join(release_path, fetch(:wsgi_path, 'wsgi'))
      execute "ln -sf #{wsgi_path}/main.wsgi #{wsgi_path}/live.wsgi"
    end
  end

  desc "Run django migrations"
  task :migrate do
    if fetch(:multidb)
      django("sync_all", '--noinput', run_on=:web)
    else
      django("migrate", "--noinput", run_on=:web)
    end
  end
end